# Third-party notices

`apps/wisp-recovery` reuses MIT-licensed work. No GPL code, and no Even Realities firmware, is in this directory.

## evenRealities-webflasher (MIT)

<https://github.com/AM-Guru/evenRealities-webflasher> at `2fcdb88`.

- `wisp_case/data/pogo_bridge.bin`: the 1,720-byte read-only pogo bridge (`src/lib/pogoBridge.js`, `POGO_BRIDGE_BASE64`), unchanged. SHA-256 `e30e143d522e5a5d0b10a92a15610badcc6aef014333716a94eae183b14dc258`.
- `wisp_case/bridge.py`: G2RQ/G2RS framing, the retained-result proof and the version-frame decoding are ported from `pogoBridge.js`; the probe sequence follows `serial.js` `probeRunningTempleOnce`.

```
MIT License

Copyright (c) 2026 evenRealities-webflasher contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## drdaeman/g2-bootloader-patch (MIT)

<https://github.com/drdaeman/g2-bootloader-patch> at `1d22097`.

- `wisp_case/rom.py` and `wisp_case/transport.py`: the STM32 ROM-loader framing and the CH340 DTR/RTS sequences are ported from `tools/g2patch/case_rom.py` (itself derived from the webflasher); the case image pin (`773b6d4c…`, B200 1.2.57) is from `tools/g2patch/data/case.json`.
- The bridge binary above is byte-identical to its `tools/g2patch/data/case_bridge.bin`.

```
MIT License

Copyright (c) 2026 Aleksei Zhukov (G2 Bootloader patch)
Copyright (c) 2026 Kalani Helekunihi (Even Realities WebFlasher and openCFW)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
