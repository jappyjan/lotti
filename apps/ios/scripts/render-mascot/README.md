# render-mascot

Renders preview PNGs of Lotti's raccoon mascot (`apps/ios/Lotti/Mascot/Art/*.swift`) on macOS
with only the Swift command line tools (no Xcode). It compiles the art files together with
`main.swift` into a small command-line tool that uses SwiftUI `ImageRenderer`.

```sh
apps/ios/scripts/render-mascot/render.sh <output-dir>
```

Outputs, light (white) and dark (black) background each:

- `large-<scheme>-glasses-<0|0.5|1>.png` — 300 pt @2x (600×600), glasses off / halfway / on.
- `large-<scheme>-pose-<pitch±15|roll±12|yaw±20>.png` — head poses, glasses on.
- `avatar108-<scheme>-glasses-*.png`, `avatar64-…` — `RaccoonAvatar` at 36 pt @3x and 64 px.
- `avatar108-<scheme>-pose-*.png` — avatar head poses.
- `body108-…`, `body64-…` — full body at small sizes.
- `contact-sheet.png` — everything on one sheet, including a glasses motion strip and a chat
  header mock with the 36 pt avatar at real size.

The build goes to `$TMPDIR/lotti-render-mascot`. It compiles in Swift 6 language mode, like the app.
