#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# wisp-fw:drivers-test. Emulation only — nothing here talks to hardware.
#
# For each panel variant (WISP_PANEL=a6n-g / jbd4010: boards/panels/<panel>.overlay; the board has no
# default panel):
#   1. build the image with wisp-core linked and the driver self-test on (main.c)
#   2. run it in Renode on renode/wisp_g2.repl: MSPI0 = the panel recorder
#      (models/WispMspiPanel.cs), IOM0..7 = the G2's I2C devices (models/WispIom.cs)
#   3. tests/drivers/check_drivers.py: the panel's command sequence and bus modes, the frame bytes
#      after a full and a partial update, the I2C traffic of every driver (no PSoC DFU command,
#      PMIC registers addressed in the right byte order, suspend writes), and the UART log.
# Then one negative case: the same image built against a pristine Zephyr tree (without
# third_party/ambiq/patches/zephyr-0002, the I2C header byte-order fix; configure check skipped
# with the TEST ONLY switch, Bluetooth off so rule 8's EM9305 check stays out of the way) must fail
# the PMIC byte-order check. WISP_DRIVERS_SKIP_NEGATIVE=1 skips it.
#
# Run dirs: .wisp-cache/drivers/<variant>/ (uart1.txt, panel.log, frame.bin, iom.log, renode.log).
source "$(dirname "$0")/lib.sh"
wisp_devshell "$@"
wisp_require_setup

# The self-test runs before Bluetooth, which then waits 5 s for the absent EM9305.
secs="${WISP_DRIVERS_SECONDS:-9}"
# A report the PSoC publishes after boot: worn (byte 0 = 2) + single tap (byte 1 = 0x04, count 1).
touch_report="02040100000000000000000000000000"

# A pristine checkout of the pinned Zephyr (git worktree of the west repo; the patches live only
# in the working tree). Same place as scripts/test.sh's.
pristine_zephyr() {
	local dir="$CACHE_DIR/unpatched/zephyr"
	if [[ ! -d "$dir" ]]; then
		git -C "$ZEPHYR_BASE" worktree prune
		git -C "$ZEPHYR_BASE" worktree add --detach --force "$dir" HEAD >/dev/null 2>&1
	fi
	git -C "$dir" checkout --detach -q "$(git -C "$ZEPHYR_BASE" rev-parse HEAD)"
	git -C "$dir" reset -q --hard
	echo "$dir"
}

# build <dir> <cmake args...>: west build, or (WISP_DRIVERS_ZEPHYR set) plain CMake against
# that Zephyr tree with the workspace's modules.
build() {
	local dir="$1"
	shift
	rm -rf "$dir" # always from scratch: a cached configure misses new board .conf files
	if [[ -z "${WISP_DRIVERS_ZEPHYR:-}" ]]; then
		WISP_BUILD_DIR="$dir" "$APP_DIR/scripts/build.sh" "$@"
		return
	fi
	local mods
	mods="$(cd "$WEST_TOP" && west list -f '{abspath}' ambiqhal_ambiq cmsis cmsis_6 mbedtls littlefs | paste -sd';')"
	ZEPHYR_BASE="$WISP_DRIVERS_ZEPHYR" cmake -GNinja -S "$APP_DIR" -B "$dir" -DBOARD=wisp_g2 \
		"-DZEPHYR_MODULES=$mods" "$@" && cmake --build "$dir"
}

run_variant() {
	local name="$1" variant="$2" expect="$3"
	shift 3
	local build="$CACHE_DIR/build/drivers-$name" run="$CACHE_DIR/drivers/$name"

	printf '\n=== wisp-fw drivers test: %s\n' "$name"
	build "$build" -DWISP_WITH_CORE=ON "$@" >"$CACHE_DIR/drivers-build-$name.log" 2>&1 || {
		tail -n 40 "$CACHE_DIR/drivers-build-$name.log" >&2
		echo "FAIL: build $name" >&2
		exit 1
	}
	rm -rf "$run"
	mkdir -p "$run"
	: >"$run/uart1.txt"
	local bin="$build/zephyr/zephyr.bin" elf="$build/zephyr/zephyr.elf" sp pc
	read -r sp pc < <(python3 -c 'import struct,sys; print("0x%08x 0x%08x" % struct.unpack_from("<II", open(sys.argv[1],"rb").read(8)))' "$bin")
	G2_CAPTURE_OUT="$run" renode --disable-gui --plain --console -e "\$bin=@$bin; \$elf=@$elf; \$sp=$sp; \$pc=$pc; \$variant=$variant; include @$APP_DIR/renode/wisp_g2.resc; iom TouchReport \"$touch_report\"; emulation RunFor \"$secs\"; panel SaveLog @$run/panel.log; panel SaveFrame @$run/frame.bin; iom SaveLog @$run/iom.log; quit" \
		>"$run/renode.log" 2>&1 || {
		tail -n 30 "$run/renode.log" >&2
		echo "FAIL: renode $name" >&2
		exit 1
	}
	local check=(python3 -I "$APP_DIR/tests/drivers/check_drivers.py" --variant "${name%%-*}" --run "$run")
	if [[ "$expect" == pass ]]; then
		"${check[@]}"
	elif "${check[@]}" >"$run/check.log" 2>&1; then
		echo "FAIL: negative case $name passed the checker" >&2
		exit 1
	elif ! grep -q "pmic: register addresses with an unknown base" "$run/check.log"; then
		cat "$run/check.log" >&2
		echo "FAIL: negative case $name failed, but not on the PMIC byte order" >&2
		exit 1
	else
		echo "ok: negative case $name rejected:"
		grep "pmic: register addresses" "$run/check.log" | sed 's/^/    /'
	fi
}

conf="$APP_DIR/tests/drivers/selftest.conf"
WISP_PANEL=a6n-g run_variant a6ng 1 pass "-DEXTRA_CONF_FILE=$conf"
WISP_PANEL=jbd4010 run_variant jbd4010 0 pass "-DEXTRA_CONF_FILE=$conf"
if [[ "${WISP_DRIVERS_SKIP_NEGATIVE:-}" != 1 ]]; then
	WISP_PANEL=a6n-g WISP_DRIVERS_ZEPHYR="$(pristine_zephyr)" run_variant a6ng-unpatched-i2c 1 fail \
		"-DEXTRA_CONF_FILE=$conf;$APP_DIR/tests/drivers/bt_off.conf" -DWISP_PATCHES_TEST_UNPATCHED=ON
fi
printf '\n=== wisp-fw drivers test: all passed\n'
