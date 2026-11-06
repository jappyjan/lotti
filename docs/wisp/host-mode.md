# Wisp host mode — running the core inside stock 2.2.6.10

Host mode is the second rung of the [ladder](safety.md#the-ladder): the Wisp
core as an **appended module** inside the stock Even main app, not a
replacement for it. Stock boots normally, stock BLE and stock OTA stay
untouched, and Wisp code runs only after a phone opens a session and only while
a short lease is held. It is the first time Wisp runs on real glasses, chosen
because the brick risk is low — the boot path is entirely stock, and nothing
Wisp does runs before BLE is up (see [W2/W3](README.md#decisions),
[safety.md](safety.md)).

This document says where to hook, how the lease arms and disarms it, the memory
budget, and a ladder of minimal hooks for the first bring-up. It is a design,
not an implementation: no host-mode code exists yet, and nothing here has run on
hardware.

## Status and sourcing

Every address is a **run address** for stock `s200_v2.2.6.10` (the build W16
pins). Two kinds of source back each fact, tagged inline:

- **openCFW** (MIT, `kalanihelekunihi/evenRealities-openCFW`), cited as
  `<file>:<line>` under `g2/docs/reference/` or `g2/symbols/apollo_main.tsv`.
- **disasm** — our own disassembly of the locally fetched stock image
  (`wisp-ota fetch 2.2.6.10` → `.wisp-cache/`, carved and disassembled per the
  commands below). No firmware bytes are committed ([safety.md rule 9](safety.md)).

Confidence: **[C]** confirmed (an openCFW doc asserts it, or we verified it in
the disassembly), **[I]** inferred, **[?]** open gap. Treat every **[I]** and
**[?]** as something to confirm against a live symbol or a capture before any
hook depends on it.

```sh
# Fetch (git-ignored) and locate the main image.
node packages/wisp-ota/dist/cli.js fetch 2.2.6.10
node packages/wisp-ota/dist/cli.js inspect .wisp-cache/stock/g2-2.2.6.10.bin
# Carve the raw app (run base 0x438000) — vector table starts 0xa0 bytes
# (0x80 component header + 0x20 preamble) after the main payload offset.
dd if=.wisp-cache/stock/g2-2.2.6.10.bin of=main.bin bs=1 skip=$((0xbde87)) \
   count=3523364 status=none
nix shell nixpkgs#gcc-arm-embedded -c arm-none-eabi-objdump -D -b binary \
   -marm -Mforce-thumb --adjust-vma=0x438000 main.bin > main.dis
```

Image install range: **`[0x00438000, 0x00794324)`**, 3,523,364 B — verified by
the carve ending exactly at `0x794324` and by `wisp-ota inspect`. Vector table
at `0x438000`: SP `0x2007FB00`, reset `0x005E4233`, NMI `0x004397A7`, HardFault
`0x005B0115` [C: disasm; matches [hardware.md](hardware.md) and `wisp-ota inspect`].

## Shape of the thing

```
MRAM  0x438000 ┌───────────────────────────────┐
               │ stock main app (unchanged)    │  installed by the Even
               │  reset, FreeRTOS, Cordio BLE, │  bootloader from the staging
               │  TPL, display, drivers…       │  file, exactly as today
     0x794324  ├───────────────────────────────┤
               │ Wisp module (appended)        │  ~399 KiB of erased MRAM:
               │  HELLO, lease, frame decode,  │  the core + a thin stock HAL.
               │  hooks into the stock funcs   │  Reached only through the hooks.
     0x7F8000  ├───────────────────────────────┤  ← Wisp ceiling
               │ (reserved margin)             │
     0x7FE000  │ bootloader update flag (16 B) │  never written by host mode
     0x800000  └───────────────────────────────┘
```

The stock image is **not rebuilt**. The Wisp module is linked to sit in the free
MRAM after the stock image end, and a small, fixed set of hook points in the
stock code are redirected to call into it. How the module and the hooks get into
MRAM in the first place (a repacked stock main image carrying the extra bytes,
built and flashed over the rung-1 OTA path) is out of scope here; this document
assumes the module is present and asks what it may do.

openCFW's own `open_cfw.py` rebuilds the main component from reconstructed source
and repacks the bundle; it documents **no** trampoline or patch-point catalogue
for the shipped image (`g2/tools/open_cfw.py:3-131` [C]). The append-and-hook
approach is new to Wisp — the reusable machinery below is the stock firmware's
own entry points, not an openCFW framework.

## Where to hook

Each hook below names the stock function, what it does, the source, and the
risk. "Runs before BLE" is the decisive safety question: a hook on the boot or
driver-init path runs before any phone, before any lease, and so is **forbidden**
(it can crash the temple into an SWD-only repair before OTA can rescue it —
[safety.md](safety.md)). The hooks Wisp needs all sit on paths that only execute
once BLE is advertising and a connection exists.

### 1. TPL receive — the one hook that matters (private sid)

The phone transport is `transport_protocol.c` (`TPL_*`), a single instance, not
a per-service pointer table (searched the image for a `{sid → fn}` table, 0 hits
[C: disasm]). Incoming packets carry the service id in header byte 6; sids
`0x04–0x91` and `0xC0–0xC7` are in use [C: `protocols.md:97-104`,
`capabilities.md:73-84`].

| Fact                    | Value                                                                        | Source                             |
| ----------------------- | ---------------------------------------------------------------------------- | ---------------------------------- |
| `TPL_Init`              | `0x004B892C`, called once at `0x004C9502` (slot 0, 4 callbacks)              | [C] `apollo_main.tsv:2909`; disasm |
| `TPL_ReceivePacket`     | `0x004B910C`; its only caller is the write callback at `0x004BDF46`          | [C] `apollo_main.tsv:2919`; disasm |
| RX-complete callback    | `Thread_MsgRxFromBle` `0x0048F12C` → BLE-RX thread queue                     | [C] `apollo_main.tsv:2043`; disasm |
| Category router         | `_thread_pb_msg_handler` `0x0048EEAC` (routes 0x80, 0xC0–0xC7, 0x200, 0x400) | [C] `apollo_main.tsv:2039`; disasm |
| `TPL_SendPacket`        | `0x004B9640`, fragments ≤4096 B and appends CRC-16                           | [C] `apollo_main.tsv:2920`         |
| CRC-16/CCITT-FALSE leaf | `0x0049ACD4`                                                                 | [C] `protocols.md:110`             |

**The hook:** redirect the category router `_thread_pb_msg_handler`
(`0x0048EEAC`) so that a chosen **private sid** is handed to the Wisp module and
every other sid falls through to the stock handler unchanged. The private sid is
the "host tunnel" the [protocol doc](protocol.md#links) left open: Wisp frames
ride inside stock TPL packets on that sid, so stock's own traffic and Wisp's
share the link without either seeing the other. Candidate free sids well clear
of stock ranges: **`0x50`, `0xB0`, `0x2A`** [I: gap analysis of byte 6]. Pick one
and record it in [protocol.md](protocol.md).

**TX back to the phone:** reuse `TPL_SendPacket` (`0x004B9640`) with the private
sid, or, for the streaming path, the ESS notify route
`APP_BleEssSendDataMsg` → `AttsHandleValueNtf(conn, 0x0864, …)`
[C: `findings-cross-cutting.md:199`, `apollo_main.tsv:5114`].

Risk: **low.** Runs only on a received packet, i.e. well after BLE is up and a
connection exists. The fall-through must be exact — a mistake here only breaks
Wisp's own sid, never stock's, as long as the default path is preserved. This is
the only hook rung 2 strictly needs (see the ladder below).

### 2. Display framebuffer path

Stock drives a **576×288** LVGL surface (not the full panel) at colour depth L8,
through a `0x14400`-byte (82,944 B) draw buffer, and pushes to the µLED panel
over MSPI0 [C: `libraries.md:150-151`, `findings-codec-em9305.md:1117`].

| Fact                      | Value                                                                                                                   | Source                                                              |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| LVGL draw buffer base     | `0x20080000` (start of SSRAM)                                                                                           | [C] `findings-codec-em9305.md:1117`; disasm (`0x46ca6e` returns it) |
| Buffer size               | `0x14400` B = 576×288×8bpp                                                                                              | [C] disasm `0x473792` (`mov r1,#0x14400`)                           |
| Display init (576×288)    | `0x00473782` → draw-buf init `0x0048AEF8`                                                                               | [C] disasm; `findings-apollo-platform.md:733`                       |
| Flush callback            | `0x004736F4` → `0x0047366C` → display-manager `0x00474066`                                                              | [C] disasm; `apollo_main.tsv:1440`                                  |
| Display write (MSPI)      | `0x0059CCDC`: reads buffer `+0x14`, length `+0x0C`, **cleans D-cache** at `0x0059CD10`, then blocking MSPI `0x004C2098` | [C] `findings-apollo-platform.md:299`                               |
| D-cache clean body        | `0x0047510E..0x00475194`, arg `{u32 addr; s32 len}`                                                                     | [C] `findings-apollo-platform.md:281`                               |
| Panel push (JBD4010)      | quad-pixel opcode `0x62`, addr `((row<<10)&0x7FC00\|col&0x3FF)<<8\|0xFF`, **640×480 4bpp**; commit `0x97`               | [C] `findings-hardware-drivers.md:358-366`                          |
| MSPI0 completion          | binary semaphore `0x20074534`, IRQ 20                                                                                   | [C] `findings-hardware-drivers.md:348`                              |
| Panel record / brightness | active record `0x20074530`; `uled_mspi_setBrightness` `0x004CA1EE`                                                      | [C] `findings-hardware-drivers.md:349,382`                          |

**The hook:** the clean design is for Wisp to own its own full-panel buffer
(640×480 4bpp = 153,600 B — too large for the 399 KiB MRAM gap _and_ a frame, so
it lives in SSRAM, not MRAM) and drive the panel write path (`0x0059CCDC` or the
display-manager `reflash` message, id 3) directly: build the transfer, **clean
the D-cache over the exact byte range**, push over MSPI0, wait on the semaphore.
Reusing stock's own write function gets the cache-clean and panel opcodes for
free and is the lower-risk choice for first bring-up.

Caveats / gaps: stock exposes only 576×288 of the 640×480 panel; reaching full
resolution means driving the JBD4010 quad-pixel path with the full address range
rather than going through stock's LVGL surface [I]. There is **no single linear
stock framebuffer** to borrow — stock renders through LVGL/NemaGFX draw buffers
and tiles out [?]. The Hongshi A6N-G variant's partial-reflash function is a
stub that never transmits [C: `findings-hardware-drivers.md:367`], so a Wisp
display HAL must handle both panels explicitly.

Risk: **medium.** Runs post-BLE (driven by a Wisp display message), but the MSPI
bus and the panel are shared with stock; Wisp and stock must not both drive the
panel at once. The lease (below) gives the arbitration: while armed, Wisp owns
the surface; on expiry, stock's display task resumes.

### 3. Touch / gesture events

| Fact              | Value                                                              | Source                                   |
| ----------------- | ------------------------------------------------------------------ | ---------------------------------------- |
| Touch controller  | PSoC 4000T, IOM5/I2C bus 5 @ `0x0C`, attention GPIO27 (active low) | [C] `findings-hardware-drivers.md:45,92` |
| Attention handler | `0x0055BA64` → `input_msg_send_touch` `0x00513056`                 | [C] `findings-hardware-drivers.md:92`    |
| Input thread      | `INP_ThreadHandler` `0x00512EF0` (init `0x00512CBC`)               | [C] `apollo_main.tsv:4471-4475`          |
| Transport slots   | RAM `0x20073E24` (cmd/raw write/read)                              | [C] `apollo_main.tsv`                    |
| Wire              | host→touch cmd = `rx[0]` (≤8); 16-B reports                        | [C] `protocols.md` §9                    |

**The hook:** tap `input_msg_send_touch` (`0x00513056`) — the single choke point
every touch report passes through on its way from the attention ISR to the input
thread — and forward the raw report to Wisp when armed. Gesture recognition in
Wisp is policy and belongs in the core, not a stock dependency.

Risk: **low.** Runs on a touch event (post-BLE). Must still feed stock's input
thread when disarmed so stock gestures keep working on lease expiry.

### 4. Sensors: IMU, ALS, wear, battery

| Source            | Function / address                                                                                                                    | Bus           | Source                                        |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ------------- | --------------------------------------------- |
| IMU ICM-45608     | INT1 (data-ready) GPIO38 → `0x004A6AE8`                                                                                               | IOM4 @ `0x69` | [C] `findings-hardware-drivers.md:44,94`      |
| Sensor-hub thread | `hub_thread_entry` `0x004A6868`                                                                                                       | —             | [C] `apollo_main.tsv:2428`                    |
| ALS OPT3007       | `ti_opt3007_assignRegistermap` `0x005135E0`; sync msg `0x10E`                                                                         | IOM2 @ `0x45` | [C] `findings-apollo-platform.md:729`, `:186` |
| Battery / PMIC    | `power_init` `0x005093D4`; nPM1300 `0x00511002..`; telemetry record `0x20073B18` (+0 status, +4 SOC, +8 mV, +0xC current, +0x10 temp) | IOM7 @ `0x6B` | [C] `findings-hardware-drivers.md:83,189`     |
| Battery sync      | sync service `0x105`, 12-B record, handler `0x005F958C`                                                                               | —             | [C] `findings-hardware-drivers.md:199`        |
| Wear              | not isolated to one symbol; lens byte `0x20075045`, surfaced via pb setting service `0x09`                                            | —             | [?] `findings-cross-cutting.md:493`           |

**The hook:** for first bring-up, **read, don't hook** — poll the stock
telemetry record `0x20073B18` (battery) and the ALS/IMU results the sensor hub
already produces, and expose them over the Wisp sensor service. A later version
can register IMU/touch data-ready callbacks for true subscriptions. Only the
2.2.6.10 charger family 1 (nPM1300) path is reachable; BQ25180/BQ27427 code is
present but unused on this build [C: `findings-hardware-drivers.md:83`]. Wear
detection has no clean symbol yet [?] — treat it as a gap and derive wear from
the IMU/proximity path later.

Risk: **low** (reads of stock state). A real IMU/ALS callback hook is **medium**
and must not starve the sensor-hub thread.

### 5. Mic: PCM / LC3

| Fact                  | Value                                                                                                      | Source                                                      |
| --------------------- | ---------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Capture ISR           | `AUD_CodecDmaInt` `0x0053C6F2` → `SVC_PcmAppProcessData` `0x0057ADF8`                                      | [C] `findings-cross-cutting.md:175`                         |
| LC3 encode            | `SVC_Lc3EncodeMono` `0x0057A940` (liblc3, 16 kHz mono, 10 ms, 40 B/frame)                                  | [C] `findings-cross-cutting.md:175`, `:217`                 |
| Stream out            | body 205 B (5 LC3 frames + metadata) → `AttsHandleValueNtf(conn, 0x0864, 205, …)` = ESS notify `…6402`     | [C] `findings-cross-cutting.md:199`                         |
| **PCM consumer hook** | `SVC_PcmAppRegister` `0x0057AB78` (source 0/1) **replaces** the owner; `SVC_PcmAppUnregister` `0x0057ACD0` | [C] `findings-cross-cutting.md:179`, `apollo_main.tsv:6350` |

**The hook:** register a Wisp PCM consumer through `SVC_PcmAppRegister`. The
sharp edge: registering **replaces** the existing owner, so stock's LC3/BLE mic
stream stops while Wisp holds it — a Wisp mic path must either forward PCM on to
stock or accept that stock's mic is off while armed, and must re-register stock's
consumer (or let the lease restore it) on disarm. Wisp can reuse
`SVC_Lc3EncodeMono` for LC3 or ship PCM raw.

Risk: **low-to-medium.** Runs post-BLE. The replace-the-owner semantics make
clean disarm mandatory.

### 6. Buzzer

`DRV_BuzzerInit` `0x00502AE8`, `DRV_BuzzerPlayNote` `0x00502BF8`,
`DRV_BuzzerStart` `0x00502C88`, `DRV_BuzzerStop` `0x00502D4C`, on TIMER7 PWM
GPIO145 [C: `apollo_main.tsv:4221-4222`, `findings-hardware-drivers.md:655`].
**The hook:** none needed — call these driver functions directly from the Wisp
audio service. Risk: **low.**

### 7. Inter-temple bridge

`uart_sync.c`: worker `uart_thread_handler` `0x005417D6`, send `uart_sync_write`
`0x00541790`, RX callback `0x005417A4`, on UART0 base `0x40039000` IRQ 15.
TinyFrame (SOF `0x01`, CRC-16/ARC, table `0x006C0950`, `TF_MAX_PAYLOAD_RX
0x6000`) [C: `apollo_main.tsv:5430`, `protocols.md` §11]. **The hook:** send a
Wisp-private TinyFrame type through `uart_sync_write` and register a listener for
it; stock's own sync types fall through. This is how the right temple forwards a
frame to the left when the phone connects to one temple only
([protocol.md topology](protocol.md#topology)). Risk: **low**, post-BLE.

### 8. BLE connection parameters / 2M PHY / DLE

`DmConnUpdate` `0x004B6D26`, `DmSetPhy` `0x004C5810`, `DmConnSetDataLen`
`0x004B6E6C`, `HciLeSetDataLen` `0x0052B176`; host ACL RX
`HciSetMaxRxAclLen(251)`, ATT MTU floor 247 [C: `apollo_main.tsv:2867,3131,2875`,
`protocols.md:76`]. Stock app-side policy: fast event `0xA3`, slow `0xA4`, app
request `0xB9`; ESS and OTA force fast [C: `protocols.md:87`]. **The hook:** when
a Wisp session wants throughput (bulk image upload), call `DmConnUpdate` for a
short interval and `DmSetPhy` for 2M, mirroring how stock's OTA path forces fast
mode (`APP_ConnectParamOTASetFastMode`). Phones clamp the interval (Android
11.25 ms, iOS 15 ms — [hardware.md](hardware.md)); request, don't assume. Risk:
**low**, post-BLE, and the lease restores stock's parameters on expiry.

## The lease — what arms host mode, and fail-open

Host mode is **disarmed at boot** and armed only by a phone. The lease is the
single switch that both arms Wisp and guarantees stock comes back.

- **Arm:** the module boots with a flag cleared. A `HELLO` on the private sid
  (hook 1) that a Wisp client sends arms the module and starts a lease with a
  short deadline (**90 s**, matching the rung-2 exit check in
  [safety.md](safety.md#the-ladder); stock's own dev-config heartbeat timer is
  30 s [C: `protocols.md:153`]). Every subsequent Wisp frame renews it.
- **Renew:** any Wisp frame (a `PING` is the keepalive —
  [protocol.md](protocol.md#0x00-session)) pushes the deadline out.
- **Disarm (fail-open):** when the deadline passes, when the phone disconnects,
  or on any Wisp fault, the module **restores stock**: it releases every hook's
  claim (re-registers stock's PCM consumer, hands the display surface back to
  stock's display task, stops forwarding touch), and returns the hooks to pure
  fall-through. Stock behaviour is then exactly as if host mode were never
  armed. The lease check itself must run from a stock timer/thread Wisp does
  **not** disable, so a hung Wisp module still expires.

Fail-open is the core safety property: the _default_ state of every hook is
"call stock and return", and arming is a positive, time-bounded, phone-driven
exception. There is no state in which a silent or crashed Wisp module leaves a
hook pointing away from stock. This mirrors the rung-2 exit check: "10 cold
boots OK; lease expiry fully restores stock; reflash stock works."

## Memory budget

**MRAM (the appended module).** Free MRAM after the stock image:
`[0x00794324, 0x007FE000)` ≈ 433 KiB by arithmetic
[C: `memory-map.md:45`], of which Wisp uses only up to the `0x7F8000` ceiling —
**408,796 B ≈ 399 KiB** (`wisp-ota inspect` reports exactly this headroom) [C].
The 16-byte bootloader update flag at `0x7FE000` and the uncharacterised
`0x7FE010..0x800000` are **never** touched. These MRAM bytes are not part of the
OTA image, so on-device they are erased `0xFF` [C for ownership; **[I]** that a
given unit reads `0xFF` there — not dumped from live hardware]. No stock NV store
lives in this gap: littlefs and the FlashDB `sysenv`/`factory` databases are on
the **external** NOR at `0x01400000`/`0x01FC0000`, not in MRAM
[C: `memory-map.md:106,153-155`]. So ≈399 KiB of code + const for the Wisp
module and its stock HAL. W16 chose 2.2.6.10 precisely because 2.3.2.14 leaves
only 9.3 KiB here.

**Heap (RAM).** Stock FreeRTOS uses **heap_4**, `configTOTAL_HEAP_SIZE =
0x2F000` (188 KiB), `ucHeap` base `0x20004558`, so the heap spans
`0x20004558..0x20033558`; `pvPortMalloc` `0x00456110` [C: disasm
`prvHeapInit` `0x00456280`; `libraries.md:110`, `memory-map.md:118`]. There is
**one** shared heap — Wisp allocations compete with stock's. The runtime
free-heap figure is not documented [?], so budget conservatively against the
188 KiB total and prefer static buffers in the MRAM module or dedicated SSRAM
over heap. The full 640×480 4bpp frame (153,600 B) must live in SSRAM
(`0x20080000+`, where stock's own draw buffer sits), not on the heap and not in
the MRAM gap.

## Ladder of minimal hooks (rung 2 bring-up)

Build host mode one hook at a time; each step must pass its check on hardware
before the next. The first step is deliberately almost nothing.

1. **HELLO and nothing else.** One hook: the TPL category router (hook 1) for the
   private sid. The module answers `HELLO` with its capability bits (all display
   and sensor caps **off**) and runs the lease timer; it touches no other
   subsystem. Check: 10 cold boots are stock; a Wisp client sees `HELLO`; the
   lease expires and stock is unchanged; a stock reflash still works. This proves
   the append, the hook, the tunnel and fail-open with the least possible risk.
2. **System reads.** Add battery/version/status reads (hook 4, reads only). Still
   no actuators. Check: values match the Even app's.
3. **Display.** Add the panel write path (hook 2) behind the lease: Wisp owns the
   surface while armed, stock's display task resumes on expiry. Check: Wisp draws;
   lease expiry restores the stock UI; no MSPI contention.
4. **Input.** Add the touch tap (hook 3). Check: Wisp sees touches while armed,
   stock gestures work when disarmed.
5. **Sensors / mic / buzzer / inter-temple / fast link.** Add hooks 4 (callbacks),
   5, 6, 7, 8 as the core needs them, each behind the lease, each with a disarm
   that restores stock (the mic's replace-the-owner semantics make its disarm the
   most important to get right).

## What host mode cannot do

- **No full boot control.** Wisp runs after stock's boot and BLE bring-up; it
  cannot change the boot path, the advertising name, the bootloader, or anything
  that runs before a lease exists. Native mode (rung 4) is for that.
- **No pre-BLE work.** Any feature that must act before a phone connects (an
  on-boot animation, wake-on-motion before advertising) is impossible in host
  mode — those paths are the forbidden pre-BLE region.
- **No replacing a co-processor's firmware** (EM9305, PSoC, GX8002, case) —
  [safety.md rule 8](safety.md). Host mode only redirects Apollo main-app
  functions.
- **Shared heap and panel.** Wisp cannot assume memory or the display/MSPI bus is
  exclusively its own; it borrows them under the lease and must give them back.
- **Full resolution and codecs are not free.** Stock exposes 576×288 via LVGL;
  640×480 means driving the panel directly [I]. The mic stream means taking over
  stock's PCM consumer.
- **Not a brick-proof install path.** Host mode is only as safe as the rung-1 OTA
  that puts the module into MRAM; the brick guards are in `wisp-ota`, not here.

## Risks per hook (and which run before BLE)

| Hook                            | Runs before BLE?    | Risk       | Main hazard                                                               |
| ------------------------------- | ------------------- | ---------- | ------------------------------------------------------------------------- |
| 1 TPL private sid               | No (on RX)          | low        | fall-through must be exact; wrong sid choice collides with stock          |
| 2 Display / MSPI                | No                  | medium     | MSPI/panel shared with stock; D-cache clean range must be exact           |
| 3 Touch tap                     | No                  | low        | must still feed stock's input thread when disarmed                        |
| 4 Sensor reads                  | No                  | low        | reads of stock state; a real callback hook must not starve the hub thread |
| 5 Mic PCM/LC3                   | No                  | low-medium | `SVC_PcmAppRegister` **replaces** the owner; disarm must restore it       |
| 6 Buzzer                        | No                  | low        | direct driver calls; no hook                                              |
| 7 Inter-temple                  | No                  | low        | private TinyFrame type; stock types must fall through                     |
| 8 Conn params / PHY             | No                  | low        | request only; lease restores stock params                                 |
| Boot / `board_init` / auto-init | **Yes — forbidden** | —          | **never hook**: runs before BLE and before any lease                      |

Forbidden pre-BLE region, for completeness: the reset vector `0x005E4233`, the
IAR entry `0x005E4254`, the auto-init table (`0x006D1E0C`, `board_init`
`0x005CDD14` is priority 0), and the scatter/heap/clock/GPU bring-up — all run
before the WSF stack registers and before the delayed-start callback
`0x004B758B` fires advertising ~10 s after init [C: `findings-hardware-drivers.md:149-153`,
`protocols.md:80`]. A watchdog (~30 s, MCU WDT LFRC/64 reset value 480, restart
`am_hal_wdt_restart` `0x0052A3DA`, kicked via `0x004B29F8`, plus the nPM1300
external WDT) will reset the temple if a Wisp hook starves the stock task that
feeds it [C: `findings-hardware-drivers.md:166-170`] — another reason every hook
must be short and must fall through when disarmed.
