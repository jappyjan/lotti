# Spike S2: R1 ring and G2 touchpad input

Status: ✅ done. Touchpad and ring gestures showed up in the Lotti app on 2026-11-01.
Goal: get R1 ring gestures and G2 touchpad events into our app while the glasses are connected, and answer "can the ring and the glasses both connect to our app at once?".

## Result

- `GlassesLink.inputs()` returns an `AsyncStream<InputEvent>`: a gesture (`tap`, `doubleTap`, `scrollUp`, `scrollDown`, `longPress`, `longPressEnd`) plus a source (`rightTouchpad`, `leftTouchpad`, `ring`, `unknown`). Each call gets its own stream.
- `G2Events.decode` (pure Swift, golden-byte tests from real captures) turns the glasses' async messages into gestures or log lines. `InputDeduplicator` drops repeats.
- The app shows the last 10 gestures under "Last input" and logs each one as `[Input] tap (ring)`.
- **There is no separate ring link.** The ring talks to the glasses, and the glasses forward its gestures to us on the same channel as the touchpads.

## How the ring connects

**The R1 is linked to the glasses, not the phone.** The glasses keep their own BLE connection to the ring and forward its gestures to the phone as EvenHub events, with `eventSource = 2` (ring). Our G2 link already receives them. Nothing to send: the ring was paired to these glasses by the Even app before, and the link survived replacing the Even app with Lotti.

How the pairing is set up in the first place (we didn't need it, so this is untested):

- MentraOS (`controllers/R1.swift`, `sgcs/G2.swift`): the phone connects to the ring directly, writes `0xFC`, `0x11` and an "advStart" with the glasses' MAC to the ring, then sends the glasses `0x80` Cmd 6 `RING_CONNECT_INFO {5: {1 connect, 2 ring MAC, 3 ring name}}`.
- g2-kit (`ble/ring.ts`): the Even app binds the ring with `cmd 0x0a` ("link to glasses", right-arm MAC) during its pairing sequence. Without it, ring gestures never reach the phone.

A new ring, or one paired to other glasses, will need this pairing flow. That's for later (onboarding), not M2.

### Ring + glasses at once?

**Yes.** With the glasses connected, the ring's gestures come through the glasses. We also tested a direct phone → ring connection (a throwaway, read-only probe; commit `396e97f`):

- The ring advertises as `EVEN R1_EEE3F8` even while linked to the glasses. Manufacturer data starts with `45 52` ("ER"), then the MAC reversed (`f8 e3 ee …`).
- The phone connected without a pairing prompt. Services: `BAE80001-4F05-4503-8E65-3AF1F7329D1F` (write `…0010`/`…0012`, notify `…0011`/`…0013`) and `FE59` (Nordic DFU, char `8EC90003-…`).
- **While the phone was connected directly, the glasses still forwarded ring taps.** Both links run side by side.
- The ring sent nothing on the direct link. According to MentraOS, it only sends `FF <type> <param>` gestures there after the phone writes init commands. We didn't write to it, to avoid disturbing the ring's link to the glasses.

So the direct link isn't needed for input. It may matter later for ring battery or health data, or for pairing a new ring.

## Event formats

All gestures arrive on the **right arm**, sid `0xE0`, flag `0x01`, Cmd 2 (`OS_NOTIFY_EVENT_TO_APP`), field 13 `SendDeviceEvent`. They carry no magic. Zero values are left out, so an absent event type means click.

```
SendDeviceEvent {
  1 List_ItemEvent {1 containerID, 2 name, 3 item name, 4 item index, 5 eventType}
  2 Text_ItemEvent {1 containerID, 2 name, 3 eventType}
  3 Sys_ItemEvent  {1 eventType, 2 eventSource, 3 IMU, 4 exit reason, 5 widget id, 6 session id}
}
eventType:   0 click, 1 scroll top, 2 scroll bottom, 3 double click, 4/5 foreground enter/exit,
             6 abnormal exit, 7 system exit, 8 IMU, 9 long press, 10 long press release
eventSource: 1 right touchpad, 2 ring, 3 left touchpad
```

What our G2 (firmware 2.2.9) sent, with one full-screen text container `lotti` on screen:

| Gesture        | From                | Payload                               | Decoded as                    |
| -------------- | ------------------- | ------------------------------------- | ----------------------------- |
| tap            | right / left / ring | `08026a041a0210` + `01` / `03` / `02` | Sys event with source         |
| double tap     | right / left / ring | `08026a061a04080310` + `01`/`03`/`02` | Sys event with source         |
| swipe / scroll | touchpads and ring  | `08026a0d120b080112056c6f7474691802`  | Text event on `lotti`, type 2 |
|                |                     | `08026a0d120b080112056c6f7474691801`  | Text event on `lotti`, type 1 |
| hold           | touchpads and ring  | `08026a041a020809`, then `…080a`      | Sys event, no source          |

Notes:

- **Scrolls and long presses carry no source.** Both look the same whether they came from a touchpad or the ring. Only taps and double taps say where they came from. For M2's gesture mapping that should be fine (same action either way). If it isn't, look at whether a list container or IMU mode adds the source.
- **Scroll direction:** we pass the firmware's names through (scroll top → `scrollUp`, scroll bottom → `scrollDown`). In the first run, "swipe forward, then back" on the right touchpad gave bottom then top. Which physical direction means "up" on the touchpad and on the ring isn't confirmed yet. Check this in M2.
- **Long press** sends a press (9) when the hold starts and a release (10) at the end.
- **No repeats.** Every gesture arrived exactly once (MentraOS debounces clicks by 100 ms and other projects report doubles). `InputDeduplicator` drops the same gesture within 150 ms, short enough not to eat fast scrolls.
- **sid `0x0D`** (state change) sent `08011a0308e001` once after our page went up: "EvenHub (`0xE0`) is now the active app". It's logged, not turned into input.
- After connecting, the right arm also sent sid `0x09` (settings) with the firmware version `2.2.9.222`.

## The left arm's sid `0x80` Cmd 6 messages (open item from S1)

**They're `RING_CONNECT_INFO` status pushes (device-config Cmd 6), not a heartbeat. No reply needed.**

- Payload `08 06 10 <counter> 2a 00`: Cmd 6, a counter in the magic field (+17 each time), and an empty `RingInfo` (field 5). Flag `0x01`, like other async pushes. The right arm sent one too, right after connecting.
- They came every **10 s** in this session (S1 noted ~4 s).
- The empty RingInfo reads "connect 0, status 0" even though the ring was working, so these don't tell us whether the ring is connected. MentraOS only reacts when the info has fields (status 22 = ring disconnected).
- We never answered. The session stayed up with only our 4 s EvenHub heartbeat: about 4 minutes in run 1 and 2 in run 2, with no disconnects.
- The phone-side keepalive is a different message: `0x80` Cmd 14 `BASE_CONNECT_HEART_BEAT {13:{}}`, which the official app sends to both arms every 60 s (even-g2-protocol `device/device.py`). We don't send it, and nothing broke. Add it if longer sessions start dropping.

## Hardware log

2026-11-01, iPhone 16 (iOS 27), G2 pair `32` (firmware 2.2.9.222), R1 `EEE3F8` linked to the glasses by the Even app earlier, Even app force-quit.

- **Run 1:** after "Send hello", tap / double tap / swipes / hold on each touchpad, then on the ring. Every gesture came through once, on the right arm. Taps and double taps had the right source (1, 3, 2). Scrolls came as text events and holds as sys events, both without a source.
- **Direct ring probe:** during run 1, "Connect ring directly" found and connected to `EVEN R1_EEE3F8` (RSSI −56) and subscribed to its three notify characteristics. It received nothing. Ring taps kept arriving through the glasses while the phone was connected to the ring.
- **Left-arm Cmd 6:** timed at 10 s intervals over a minute, with heartbeats every 4 s. No disconnects.
- **Run 2** (final build, without the probe): ring tap → `tap (ring)`, right touchpad tap → `tap (rightTouchpad)`, plus one swipe → `scrollUp (unknown)`. All three showed in "Last input".
