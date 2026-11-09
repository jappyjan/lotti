// SPDX-License-Identifier: MIT
// Wisp W18 Renode model: the temple's UART2 (0x4003B000), i.e. the pogo link to the charging case,
// with a host tool on the other end instead of the case relay. Used by tests/boot/w18.py to drive
// drdaeman's patched bootloader (its UART2 RAM loader) with the same host code that runs against
// the real case (apps/wisp-recovery).
//
// Register behaviour (PL011 subset the loader and the stock code use): DR (0x00) write = one TX
// byte, DR read = next RX byte (error bits only from the half-duplex model below); FR (0x18) = TXFE |
// (RXFE when nothing is queued), never BUSY or TXFF; RSR (0x04) = the last byte's errors (0 unless the
// half-duplex model corrupted it), a write clears them; every other offset is plain storage. No interrupt is ever raised (the loader
// polls with IRQ 17 masked; the stock app copes with an idle UART2, as WispUartIdle shows).
//
// The model frames the temple's output: a frame is 5A A5 FF <len> followed by len + 1 bytes (the
// loader's HELO/OKAY/RLSD/RESP). Every complete frame is appended to Frames (`uart2 FrameLog`).
//
// Lockstep host link (`uart2 Listen <port>`): a TCP client on 127.0.0.1:<port>. Each complete
// temple frame is sent to the client as [u16 LE length][bytes]; then the CPU thread BLOCKS inside
// the DR write until the client answers with [u16 LE length][bytes]: length 0 = queue nothing,
// otherwise the bytes are queued as RX. Length 0xFFFF detaches the host (later frames are only
// logged). Virtual time does not advance while blocked, so the host's real-time latency never
// eats into the loader's 500 ms boot window: this is the deterministic equivalent of the case
// relay's one-request/one-reply G2TX/G2RX exchange. A host that stays silent for HostTimeoutMs
// real milliseconds is detached.
//
// Half-duplex wire (`uart2 HalfDuplex true`; rung4.md, "W24d: stage-0b"). On the G2 the case link is
// ONE pogo wire: pad 42 (UART2TX, function 4) and pad 44 (UART2RX, function 4) both sit on it, and
// the loader and stock turn it round for every send (park the other pad, function 3). With the
// model on, it follows the two pads (WispPads, the GPIO record in WispTrace.cs):
//   * a byte the temple writes while pad 42 is not in UART function never reaches the wire: it is
//     not framed or sent to the host (TxLost);
//   * bytes from the case (the host's reply, Inject) wait on the wire until pad 44 is in UART
//     function; if pad 42 is in UART function too at that moment, the temple's own TX pad drives
//     the wire against them, and every byte arrives with a framing error (DR bit 8 FE, RSR FE;
//     RxCorrupted). That is what the W24/W24b UART set-up (both pads in function 4 for good) does.
// BothUart counts pad writes that left both pads in UART function at once (any code, PCs in
// BothUartLog); the harnesses fail Wisp code on it. With the model off (the default) bytes are
// received at once and pads are ignored, as before.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispCaseLink : IDoubleWordPeripheral, IBytePeripheral, IWordPeripheral, IKnownSize
    {
        public WispCaseLink(IMachine machine)
        {
            this.machine = machine;
            Frames = new List<string>();
            Reset();
        }

        public long Size => 0x1000;

        public List<string> Frames { get; }
        public List<double> Times { get; } = new List<double>();
        public bool TimeLog { get; set; }

        // Virtual time (ms) of every logged frame, for timing analysis.
        public string TimeLogDump()
        {
            return string.Join("\n", Times.Select(t => t.ToString("F3")));
        }
        public int HostTimeoutMs { get; set; } = 120000;
        public ulong TxBytes { get; private set; }
        public ulong RxBytes { get; private set; }
        public bool HostAttached => client != null;

        // Peripheral reset (also on every emulated power cut): registers and FIFOs only. The host
        // link and the frame log survive, like the case relay survives a temple reset.
        public void Reset()
        {
            regs = new Dictionary<long, uint>();
            rx = new Queue<uint>();
            tx = new List<byte>();
            wire = new Queue<byte>();
            rsr = 0;
        }

        public bool HalfDuplex { get; set; }
        public ulong TxLost { get; private set; }
        public ulong RxCorrupted { get; private set; }
        public long BothUart => WispPads.BothUart;

        public string PadLog()
        {
            return string.Join("\n", WispPads.Log);
        }

        public string BothUartLog()
        {
            return string.Join("\n", WispPads.BothUartLog);
        }

        // One line for the harness: "tx_lost=<n> rx_corrupted=<n> both_uart=<n> waiting=<n>".
        public string WireReport()
        {
            return $"tx_lost={TxLost} rx_corrupted={RxCorrupted} both_uart={WispPads.BothUart} waiting={wire.Count}";
        }

        // Bytes from the case reach the receiver once pad 44 listens; corrupted if pad 42 drives.
        private void Deliver()
        {
            if(!HalfDuplex || wire.Count == 0 || !WispPads.RxListening)
            {
                return;
            }
            var corrupt = WispPads.TxDriving;
            while(wire.Count > 0)
            {
                var b = wire.Dequeue();
                if(corrupt)
                {
                    RxCorrupted++;
                }
                rx.Enqueue(corrupt ? 0x100u | b : b);
            }
        }

        private void FromCase(byte b)
        {
            if(HalfDuplex)
            {
                wire.Enqueue(b);
            }
            else
            {
                rx.Enqueue(b);
            }
        }

        public void Listen(int port)
        {
            listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            this.Log(LogLevel.Info, "W18 case link: waiting for a host on port {0}", port);
            client = listener.AcceptTcpClient();
            client.NoDelay = true;
            stream = client.GetStream();
            this.Log(LogLevel.Info, "W18 case link: host attached");
        }

        // Model limit: Renode 1.16's Cortex-M55 has no MVE, so `vmrs rX, vpr` / `vmsr vpr, rX`
        // (valid on the real Apollo510) raise UNDEFINSTR. drdaeman's loader trampoline uses one
        // of each to save/restore VPR around a RAM program. MveVprShim(read, write, reg) emulates
        // exactly those two instructions: the read yields 0, the write is a no-op.
        public void MveVprShim(ulong readAt, ulong writeAt, int reg)
        {
            foreach(var c in machine.SystemBus.GetCPUs())
            {
                if(c is ICPUWithHooks h)
                {
                    h.AddHook(readAt, (cpu, a) => { cpu.SetRegister(reg, 0); cpu.PC = a + 4; });
                    h.AddHook(writeAt, (cpu, a) => { cpu.PC = a + 4; });
                }
            }
        }

        // Model limit: in Renode the stock bootloader's short FreeRTOS delays (tickless idle on the
        // Apollo4 STIMER model) overshoot by a growing amount, about +1 ms every ten calls, so a
        // long loader session slows down quadratically in virtual time. PacingShim(entry, ranges)
        // makes a call of the delay function at `entry` return at once when its return address
        // lies in one of the "lo-hi" hex ranges (the loader's reply/receive/transmit pacing) and
        // it asks for at most maxTicks. Nothing else changes: the manager's 512-tick boot window
        // and its hold loop keep their real delays. Count = how many delays were skipped.
        public ulong PacingSkipped { get; private set; }

        public void PacingShim(ulong entry, string ranges, uint maxTicks)
        {
            var spans = ranges.Split(',').Select(r => r.Split('-'))
                .Select(r => (Convert.ToUInt64(r[0], 16), Convert.ToUInt64(r[1], 16))).ToList();
            foreach(var c in machine.SystemBus.GetCPUs())
            {
                if(c is ICPUWithHooks h)
                {
                    h.AddHook(entry, (cpu, a) =>
                    {
                        var lr = cpu.GetRegister(14).RawValue & ~1UL;
                        var ticks = cpu.GetRegister(0).RawValue;
                        if(ticks <= maxTicks && spans.Any(s => lr >= s.Item1 && lr < s.Item2))
                        {
                            PacingSkipped++;
                            cpu.SetRegister(0, 0);
                            cpu.PC = lr;
                        }
                    });
                }
            }
        }

        // Harness: queue bytes for the temple to receive, as if the case had sent them (no host
        // attached). Used for the case-UART status queries (docs/wisp/case-uart.md).
        public void Inject(string hex)
        {
            foreach(var h in hex.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries))
            {
                for(var i = 0; i + 1 < h.Length; i += 2)
                {
                    FromCase(Convert.ToByte(h.Substring(i, 2), 16));
                }
            }
        }

        public string FrameLog()
        {
            return string.Join("\n", Frames);
        }

        public uint ReadDoubleWord(long o)
        {
            Deliver();
            if(o == 0x00)
            {
                if(rx.Count == 0)
                {
                    return 0;
                }
                RxBytes++;
                var d = rx.Dequeue();
                rsr = (d >> 8) & 0xF;
                return d;
            }
            if(o == 0x18)
            {
                return rx.Count == 0 ? 0x90u : 0x80u; // TXFE | RXFE, or TXFE only
            }
            if(o == 0x04)
            {
                return rsr; // RSR: the last byte's errors (a write there is ECR, "clear errors")
            }
            return regs.TryGetValue(o, out var v) ? v : 0;
        }

        public void WriteDoubleWord(long o, uint v)
        {
            if(o == 0x04)
            {
                rsr = 0;
                return;
            }
            if(o != 0x00)
            {
                regs[o] = v;
                return;
            }
            if(HalfDuplex && !WispPads.TxDriving)
            {
                TxLost++; // pad 42 is not UART2TX: the byte never reaches the wire
                return;
            }
            TxBytes++;
            tx.Add((byte)v);
            // Resynchronise on the 5A A5 FF prefix; drop anything before it.
            while(tx.Count > 0 && tx[0] != 0x5A)
            {
                tx.RemoveAt(0);
            }
            if(tx.Count >= 2 && tx[1] != 0xA5 || tx.Count >= 3 && tx[2] != 0xFF)
            {
                tx.RemoveAt(0);
                return;
            }
            if(tx.Count < 4 || tx.Count < tx[3] + 5)
            {
                return;
            }
            var frame = tx.ToArray();
            tx.Clear();
            Frames.Add(BitConverter.ToString(frame).Replace("-", "").ToLowerInvariant());
            if(TimeLog)
            {
                Times.Add(machine.LocalTimeSource.ElapsedVirtualTime.TotalMilliseconds);
            }
            Exchange(frame);
        }

        private void Exchange(byte[] frame)
        {
            if(stream == null)
            {
                return;
            }
            try
            {
                var head = new byte[] { (byte)frame.Length, (byte)(frame.Length >> 8) };
                stream.Write(head, 0, 2);
                stream.Write(frame, 0, frame.Length);
                stream.Flush();
                client.ReceiveTimeout = HostTimeoutMs;
                var len = ReadExact(2);
                var n = len[0] | len[1] << 8;
                if(n == 0xFFFF)
                {
                    Detach("host detached");
                    return;
                }
                foreach(var b in ReadExact(n))
                {
                    FromCase(b);
                }
            }
            catch(Exception e)
            {
                Detach("host link failed: " + e.Message);
            }
        }

        private byte[] ReadExact(int n)
        {
            var buf = new byte[n];
            var at = 0;
            while(at < n)
            {
                var got = stream.Read(buf, at, n - at);
                if(got <= 0)
                {
                    throw new Exception("connection closed");
                }
                at += got;
            }
            return buf;
        }

        private void Detach(string why)
        {
            this.Log(LogLevel.Info, "W18 case link: {0}", why);
            try
            {
                client?.Close();
                listener?.Stop();
            }
            catch(Exception)
            {
            }
            stream = null;
            client = null;
            listener = null;
        }

        public byte ReadByte(long o) { return (byte)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 3))); }
        public ushort ReadWord(long o) { return (ushort)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 2))); }
        // Narrow writes: DR takes the byte as it is; any other register is updated in place (a
        // compiler may set CR's TXE/RXE, bits 8-9, with a byte store to 0x31).
        public void WriteByte(long o, byte v) { WriteNarrow(o, v, 0xFFu); }
        public void WriteWord(long o, ushort v) { WriteNarrow(o, v, 0xFFFFu); }

        private void WriteNarrow(long o, uint v, uint mask)
        {
            var w = o & ~3L;
            if(w == 0x00)
            {
                WriteDoubleWord(0x00, v);
                return;
            }
            var shift = (int)(8 * (o & 3));
            var old = regs.TryGetValue(w, out var cur) ? cur : 0;
            regs[w] = (old & ~(mask << shift)) | ((v & mask) << shift);
        }

        private readonly IMachine machine;
        private Dictionary<long, uint> regs;
        private Queue<uint> rx;
        private Queue<byte> wire;
        private uint rsr;
        private List<byte> tx;
        private TcpListener listener;
        private TcpClient client;
        private NetworkStream stream;
    }
}
