#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# wisp-fw:test. Emulation and host only — nothing here talks to hardware.
#
#   1. Wisp Boot decision logic, host unit tests (gcc + ASan/UBSan); Wisp Boot build + the
#      image and rule 8 gates on it (the rung-3 fault tests are wisp-fw:boot-test)
#   2. post-build gate unit tests (synthetic images, configs, maps, symbols)
#   3. Renode boot of the built image: banner + heartbeats on UART1
#   4. safety rule 8 negative builds: each must FAIL, with the rule 8 message
#        a. Bluetooth on                         -> configure-time gate
#        b. Bluetooth on + Wisp switches set     -> post-build gate (unpatched fork)
#        c. EM9305 image linked (canary)         -> post-build gate
#        d. the canary ELF with symbols stripped  -> byte check alone still rejects it
#
# WISP_TEST_SKIP_NEGATIVE=1 skips step 4 (each negative build takes about a minute).
source "$(dirname "$0")/lib.sh"
wisp_devshell "$@"
wisp_require_setup

out="$CACHE_DIR/test"
mkdir -p "$out"
step() { printf '\n=== wisp-fw test: %s\n' "$*"; }

step "1/4 Wisp Boot host unit tests"
cc -std=c11 -Wall -Wextra -Werror -g -fsanitize=address,undefined -fno-sanitize-recover=all \
	-I"$APP_DIR/src/boot" "$APP_DIR/src/boot/wisp_boot.c" "$APP_DIR/tests/boot/test_wisp_boot.c" \
	-o "$out/test_wisp_boot"
"$out/test_wisp_boot"
"$APP_DIR/scripts/build_boot.sh" >/dev/null
echo "ok: Wisp Boot built, check_image + check_rule8 passed"

step "2/4 post-build gate unit tests"
python3 -I "$APP_DIR/tests/scripts/test_checks.py"

step "3/4 Renode boot"
secs=6
run_dir="$out/sim"
mkdir -p "$run_dir"
WISP_SIM_RUN_DIR="$run_dir" "$APP_DIR/scripts/sim.sh" "$secs" >/dev/null
python3 -I "$APP_DIR/tests/sim/check_uart.py" "$run_dir/uart1.txt" $((secs - 1))
cat "$run_dir/uart1.txt"

if [[ "${WISP_TEST_SKIP_NEGATIVE:-}" == 1 ]]; then
	step "4/4 rule 8 negative builds: SKIPPED (WISP_TEST_SKIP_NEGATIVE=1)"
	exit 0
fi

# expect_fail <name> <pattern> <cmake args...>: the build must fail and print <pattern>.
expect_fail() {
	local name="$1" pattern="$2"
	shift 2
	local log="$out/neg-$name.log"
	if WISP_BUILD_DIR="$CACHE_DIR/build/neg-$name" "$APP_DIR/scripts/build.sh" "$@" >"$log" 2>&1; then
		echo "FAIL: negative build '$name' succeeded; rule 8 gate did not fire (log: $log)" >&2
		exit 1
	fi
	if ! grep -q -- "$pattern" "$log"; then
		echo "FAIL: negative build '$name' failed, but not with '$pattern' (log: $log)" >&2
		tail -n 30 "$log" >&2
		exit 1
	fi
	echo "ok: '$name' rejected:"
	grep -E "WISP SAFETY RULE 8|check_rule8: FAIL" "$log" | sed 's/^/    /' | head -n 8
}

step "4/4 rule 8 negative builds"
bt_overlay="-DEXTRA_DTC_OVERLAY_FILE=$APP_DIR/tests/rule8/bt.overlay"
expect_fail bt "WISP SAFETY RULE 8" \
	"-DEXTRA_CONF_FILE=$APP_DIR/tests/rule8/bt.conf" "$bt_overlay"
expect_fail bt-allowed "check_rule8: FAIL" \
	"-DEXTRA_CONF_FILE=$APP_DIR/tests/rule8/bt_allowed.conf" "$bt_overlay"
expect_fail canary "check_rule8: FAIL: forbidden symbol linked: ble_fw_image_bin_" \
	-DWISP_RULE8_CANARY=ON

# d: symbols gone, only the raw-bytes check can see the image.
canary_dir="$CACHE_DIR/build/neg-canary"
arm-none-eabi-strip -o "$out/canary-stripped.elf" "$canary_dir/zephyr/zephyr.elf"
if python3 -I "$APP_DIR/scripts/check_rule8.py" --elf "$out/canary-stripped.elf" \
	--bin "$canary_dir/zephyr/zephyr.bin" --map "$canary_dir/zephyr/zephyr.map" \
	--config "$canary_dir/zephyr/.config" --compile-commands "$canary_dir/compile_commands.json" \
	--hal "$WEST_TOP/modules/hal/ambiq" >"$out/neg-stripped.log" 2>&1; then
	echo "FAIL: stripped canary passed check_rule8.py" >&2
	exit 1
fi
grep -q "EM9305 firmware bytes found" "$out/neg-stripped.log" || {
	echo "FAIL: stripped canary rejected, but not by the byte check" >&2
	cat "$out/neg-stripped.log" >&2
	exit 1
}
echo "ok: 'canary, stripped' rejected by the byte check:"
grep "bytes found" "$out/neg-stripped.log" | sed 's/^/    /' | head -n 3

step "all passed"
