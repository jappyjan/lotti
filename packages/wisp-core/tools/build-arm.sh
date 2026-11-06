#!/bin/sh
# Compile-only check for the Cortex-M55 target, plus the portability rule:
# the core may only call memcpy, memmove, memset and memcmp (and compiler helpers).
set -e
cd "$(dirname "$0")/.."
out=build-arm
mkdir -p $out
for f in src/*.c; do
  arm-none-eabi-gcc -std=c11 -mcpu=cortex-m55 -mthumb -Os -Wall -Wextra -Werror -ffunction-sections \
    -Iinclude -c "$f" -o "$out/$(basename "$f" .c).o"
done
rm -f $out/wisp_core.o
arm-none-eabi-ld -r -o $out/wisp_core.o $out/*.o
bad=$(arm-none-eabi-nm -u $out/wisp_core.o | awk '{print $2}' | grep -v -E '^(memcpy|memmove|memset|memcmp|__aeabi_.*)$' | sort -u || true)
if [ -n "$bad" ]; then
  echo "wisp-core calls outside the allowed libc subset: $bad" >&2
  exit 1
fi
arm-none-eabi-size $out/wisp_core.o
