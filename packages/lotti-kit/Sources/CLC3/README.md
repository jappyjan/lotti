# CLC3

Google's [liblc3](https://github.com/google/liblc3) (Apache-2.0, see `LICENSE`), vendored as a C
target so LottiKit can decode the G2 glasses' LC3 microphone stream.

- Upstream commit `f9c127fd35975a0494b9e187589501ee984dc4b6` (2026-10-23).
- Copied unchanged: `src/*.c`, `src/*.h`, `include/lc3.h` and `include/lc3_private.h`.
  Left out: `lc3_cpp.h` (C++ wrapper), build files, tools and tests.
