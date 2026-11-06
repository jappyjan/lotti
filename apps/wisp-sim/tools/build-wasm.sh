#!/bin/sh
# Builds the Wisp core + sim HAL into dist/wisp-sim.wasm (clang, wasm32, no libc).
set -e
cd "$(dirname "$0")/.."
core=../../packages/wisp-core
mkdir -p dist
clang --target=wasm32 -std=c11 -O2 -mbulk-memory -nostdlib -Wall -Wextra -Werror \
  -Isrc/c/include -I$core/include \
  $core/src/*.c src/c/sim.c \
  -Wl,--no-entry -Wl,-z,stack-size=1048576 -Wl,--strip-debug \
  -o dist/wisp-sim.wasm
ls -l dist/wisp-sim.wasm | awk '{print "dist/wisp-sim.wasm", $5, "bytes"}'
