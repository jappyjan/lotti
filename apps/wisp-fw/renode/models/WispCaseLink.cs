// SPDX-License-Identifier: MIT
// Wisp W18 Renode model: the temple's UART2 (0x4003B000), i.e. the pogo link to the charging case,
// with a host tool on the other end instead of the case relay. Used by tests/boot/w18.py to drive
// drdaeman's patched bootloader (its UART2 RAM loader) with the same host code that runs against
// the real case (apps/wisp-recovery).
//
// Register behaviour (PL011 subset the loader and the stock code use): DR (0x00) write = one TX
// byte, DR read = next RX byte (no error bits); FR (0x18) = TXFE | (RXFE when nothing is queued),
// never BUSY or TXFF; every other offset is plain storage. No interrupt is ever raised (the loader
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
            rx = new Queue<byte>();
            tx = new List<byte>();
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

        public string FrameLog()
        {
            return string.Join("\n", Frames);
        }

        public uint ReadDoubleWord(long o)
        {
            if(o == 0x00)
            {
                if(rx.Count == 0)
                {
                    return 0;
                }
                RxBytes++;
                return rx.Dequeue();
            }
            if(o == 0x18)
            {
                return rx.Count == 0 ? 0x90u : 0x80u; // TXFE | RXFE, or TXFE only
            }
            return regs.TryGetValue(o, out var v) ? v : 0;
        }

        public void WriteDoubleWord(long o, uint v)
        {
            if(o != 0x00)
            {
                regs[o] = v;
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
                    rx.Enqueue(b);
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
        public void WriteByte(long o, byte v) { WriteDoubleWord(o & ~3L, v); }
        public void WriteWord(long o, ushort v) { WriteDoubleWord(o & ~3L, v); }

        private readonly IMachine machine;
        private Dictionary<long, uint> regs;
        private Queue<byte> rx;
        private List<byte> tx;
        private TcpListener listener;
        private TcpClient client;
        private NetworkStream stream;
    }
}
