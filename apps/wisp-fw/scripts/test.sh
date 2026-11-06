#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# wisp-fw:test. Emulation and host only — nothing here talks to hardware.
#
#   1. Wisp Boot decision logic and the display flush path, host unit tests (gcc + ASan/UBSan);
#      Wisp Boot build + the image and rule 8 gates on it (the rung-3 fault tests are
#      wisp-fw:boot-test; the driver tests in Renode are wisp-fw:drivers-test)
#   2. the BLE transport adapter (src/link/), host unit tests with a fake GATT target
#   3. post-build gate unit tests (synthetic images, configs, maps, symbols, units, code)
#   4. Renode boot of the built image: banner, drivers up against the bus models, Bluetooth
#      gives up on the absent EM9305 without any update / recovery attempt, heartbeats on UART1
#   5. end to end over BLE: the same app on native_sim/native/64 behind a virtual controller
#      (Bumble), the TypeScript SDK completes HELLO through a GATT central (tests/ble/)
#   6. safety rule 8 negative builds: each must FAIL, with the rule 8 message
#        a. Bluetooth on without CONFIG_WISP_BT_ALLOWED  -> configure-time gate
#        b. hal_ambiq without Wisp's patch                -> configure-time gate
#        c. Zephyr without Wisp's patch                   -> configure-time gate
#           (and, Bluetooth off, without the I2C byte-order patch -> configure-time check)
#        d. hal_ambiq without the patch, gate skipped     -> post-build gate (TEST ONLY switch)
#        e. EM9305 image linked (canary)                  -> post-build gate
#        f. the canary ELF with symbols stripped          -> byte check alone still rejects it
#
# WISP_TEST_SKIP_NEGATIVE=1 skips step 6 (the full negative builds take about a minute each).
source "$(dirname "$0")/lib.sh"
wisp_devshell "$@"
wisp_require_setup

out="$CACHE_DIR/test"
mkdir -p "$out"
step() { printf '\n=== wisp-fw test: %s\n' "$*"; }
san=(-std=c11 -Wall -Wextra -Werror -g -fsanitize=address,undefined -fno-sanitize-recover=all)
core="$REPO_ROOT/packages/wisp-core"

step "1/6 host unit tests (Wisp Boot, display flush)"
cc "${san[@]}" -I"$APP_DIR/src/boot" "$APP_DIR/src/boot/wisp_boot.c" "$APP_DIR/tests/boot/test_wisp_boot.c" \
	-o "$out/test_wisp_boot"
"$out/test_wisp_boot"
cc "${san[@]}" -I"$APP_DIR/src/display" "$APP_DIR/src/display/wisp_flush.c" \
	"$APP_DIR/tests/display/test_flush.c" -o "$out/test_flush"
"$out/test_flush"
"$APP_DIR/scripts/build_boot.sh" >/dev/null
echo "ok: Wisp Boot built, check_image + check_rule8 passed"

step "2/6 BLE transport adapter host unit tests"
cc "${san[@]}" -I"$APP_DIR/src/hal" -I"$APP_DIR/src/link" -I"$core/include" \
	"$APP_DIR/src/link/wisp_link.c" "$APP_DIR/tests/link/test_wisp_link.c" \
	"$core/src/conn.c" "$core/src/session.c" "$core/src/frame.c" "$core/src/msg.c" \
	"$core/src/msgs.c" "$core/src/crc.c" -o "$out/test_wisp_link"
"$out/test_wisp_link"

step "3/6 post-build gate unit tests"
python3 -I "$APP_DIR/tests/scripts/test_checks.py"

step "4/6 Renode boot"
secs=10
run_dir="$out/sim"
mkdir -p "$run_dir"
WISP_SIM_RUN_DIR="$run_dir" "$APP_DIR/scripts/sim.sh" "$secs" >/dev/null
python3 -I "$APP_DIR/tests/sim/check_uart.py" "$run_dir/uart1.txt" 3
cat "$run_dir/uart1.txt"

step "5/6 BLE end to end: TypeScript SDK -> GATT -> native_sim firmware"
sdk="$REPO_ROOT/packages/wisp-sdk-ts/dist/index.js"
[[ -f "$sdk" ]] || {
	echo "FAIL: $sdk missing; run: pnpm nx run wisp-sdk-ts:build" >&2
	exit 1
}
command -v node >/dev/null || {
	echo "FAIL: node not on PATH (the e2e test runs the SDK in Node)" >&2
	exit 1
}
sim_build="$CACHE_DIR/build/wisp-fw-sim"
WISP_BOARD=native_sim/native/64 WISP_BUILD_DIR="$sim_build" "$APP_DIR/scripts/build.sh" \
	>"$out/build-sim.log" 2>&1 || {
	tail -n 30 "$out/build-sim.log" >&2
	exit 1
}
WISP_E2E_EXE="$sim_build/zephyr/zephyr.exe" WISP_E2E_BRIDGE="$APP_DIR/tests/ble/bumble_bridge.py" \
	WISP_E2E_LOG="$out/e2e-firmware.log" \
	node --test --test-timeout=60000 --test-reporter=spec "$APP_DIR/tests/ble/e2e.test.mts"
echo "firmware log: $out/e2e-firmware.log"

if [[ "${WISP_TEST_SKIP_NEGATIVE:-}" == 1 ]]; then
	step "6/6 rule 8 negative builds: SKIPPED (WISP_TEST_SKIP_NEGATIVE=1)"
	exit 0
fi

# expect_fail <name> <pattern> <command...>: the command must fail and print <pattern>.
expect_fail() {
	local name="$1" pattern="$2"
	shift 2
	local log="$out/neg-$name.log"
	if "$@" >"$log" 2>&1; then
		echo "FAIL: negative build '$name' succeeded; rule 8 gate did not fire (log: $log)" >&2
		exit 1
	fi
	if ! grep -q -- "$pattern" "$log"; then
		echo "FAIL: negative build '$name' failed, but not with '$pattern' (log: $log)" >&2
		tail -n 30 "$log" >&2
		exit 1
	fi
	echo "ok: '$name' rejected:"
	grep -E "WISP SAFETY RULE 8|check_rule8: FAIL|WISP: patch missing" "$log" | sed 's/^/    /' | head -n 8
}
west_build() { # <name> <cmake args...>
	local name="$1"
	shift
	WISP_BUILD_DIR="$CACHE_DIR/build/neg-$name" "$APP_DIR/scripts/build.sh" "$@"
}

# Pristine checkouts of the two patched projects at their pinned commits (git worktrees of the
# west repos: the patches live only in the working trees, so HEAD is unpatched).
unpatched() { # <west project dir> <name> -> prints the pristine tree
	local repo="$1" dir="$CACHE_DIR/unpatched/$2"
	if [[ ! -d "$dir" ]]; then
		git -C "$repo" worktree prune
		git -C "$repo" worktree add --detach --force "$dir" HEAD >/dev/null 2>&1
	fi
	git -C "$dir" checkout --detach -q "$(git -C "$repo" rev-parse HEAD)"
	git -C "$dir" reset -q --hard
	echo "$dir"
}
hal="$WEST_TOP/modules/hal/ambiq"
pristine_hal="$(unpatched "$hal" hal_ambiq)"
pristine_zephyr="$(unpatched "$ZEPHYR_BASE" zephyr)"
others="$(cd "$WEST_TOP" && west list -f '{abspath}' cmsis cmsis_6 mbedtls littlefs | paste -sd';')"
# cmake_build <name> <zephyr base> <hal dir> <configure only: 1|0> <cmake args...>: outside west,
# so ZEPHYR_BASE and the module list can point at the pristine trees.
cmake_build() {
	local name="$1" zbase="$2" haldir="$3" configure_only="$4"
	shift 4
	local dir="$CACHE_DIR/build/neg-$name"
	rm -rf "$dir"
	ZEPHYR_BASE="$zbase" cmake -GNinja -S "$APP_DIR" -B "$dir" -DBOARD=wisp_g2 \
		"-DZEPHYR_MODULES=$haldir;$others" "$@" || return 1
	[[ "$configure_only" == 1 ]] && return 0
	cmake --build "$dir"
}

step "6/6 rule 8 negative builds"
expect_fail bt "WISP SAFETY RULE 8" \
	west_build bt "-DEXTRA_CONF_FILE=$APP_DIR/tests/rule8/bt.conf"
expect_fail hal-unpatched "hal_ambiq-0001-em9305-never-write-nvm.patch is not applied" \
	cmake_build hal-unpatched "$ZEPHYR_BASE" "$pristine_hal" 1
expect_fail zephyr-unpatched "zephyr-0001-em9305-never-write-nvm.patch is not applied" \
	cmake_build zephyr-unpatched "$pristine_zephyr" "$hal" 1
expect_fail zephyr-i2c-unpatched "WISP: patch missing: zephyr-0002-i2c-ambiq-offset-byte-order.patch" \
	cmake_build zephyr-i2c-unpatched "$pristine_zephyr" "$hal" 1 \
	"-DEXTRA_CONF_FILE=$APP_DIR/tests/drivers/bt_off.conf"
expect_fail hal-unpatched-built "check_rule8: FAIL" \
	cmake_build hal-unpatched-built "$ZEPHYR_BASE" "$pristine_hal" 0 -DWISP_RULE8_TEST_UNPATCHED=ON
expect_fail canary "check_rule8: FAIL: forbidden symbol linked: ble_fw_image_bin_" \
	west_build canary -DWISP_RULE8_CANARY=ON

# f: symbols gone, only the raw-bytes check can see the image.
canary_dir="$CACHE_DIR/build/neg-canary"
arm-none-eabi-strip -o "$out/canary-stripped.elf" "$canary_dir/zephyr/zephyr.elf"
if python3 -I "$APP_DIR/scripts/check_rule8.py" --elf "$out/canary-stripped.elf" \
	--bin "$canary_dir/zephyr/zephyr.bin" --map "$canary_dir/zephyr/zephyr.map" \
	--config "$canary_dir/zephyr/.config" --compile-commands "$canary_dir/compile_commands.json" \
	--hal "$hal" --zephyr "$ZEPHYR_BASE" >"$out/neg-stripped.log" 2>&1; then
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
