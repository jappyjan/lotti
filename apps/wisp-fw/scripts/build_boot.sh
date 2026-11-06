#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build Wisp Boot (bare metal, src/boot/) into .wisp-cache/build/wisp-boot/ and run the same
# post-build gates as the Zephyr app on it: check_image.py (rules 1, 3) and check_rule8.py.
# Extra args go to CMake (e.g. -DWISP_BOOT_TEST_APPS=ON).
source "$(dirname "$0")/lib.sh"
wisp_devshell "$@"
wisp_require_setup

out="${WISP_BOOT_BUILD_DIR:-$CACHE_DIR/build/wisp-boot}"
cmake -S "$APP_DIR/src/boot" -B "$out" -G Ninja \
	-DLITTLEFS_DIR="$WEST_TOP/modules/fs/littlefs" "$@" >/dev/null
cmake --build "$out"

# Rule 8 needs a Kconfig file; Wisp Boot has none, so an empty one (no CONFIG_BT) stands in.
: >"$out/no-kconfig.config"
python3 -I "$APP_DIR/scripts/check_image.py" --elf "$out/wisp_boot.elf" --bin "$out/wisp_boot.bin"
python3 -I "$APP_DIR/scripts/check_rule8.py" --elf "$out/wisp_boot.elf" --bin "$out/wisp_boot.bin" \
	--map "$out/wisp_boot.map" --config "$out/no-kconfig.config" \
	--compile-commands "$out/compile_commands.json" --hal "$WEST_TOP/modules/hal/ambiq"
