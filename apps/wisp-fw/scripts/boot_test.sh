#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# wisp-fw:boot-test — rung 3 (docs/wisp/safety.md): Wisp Boot in Renode with the REAL Even
# bootloader and the real Wisp app behind it. Emulation only; nothing here talks to hardware.
#
#   1. stock bundles in the git-ignored .wisp-cache/stock/: 2.4.0.24 (the version on Jan's temples,
#      or $WISP_STOCK_VERSION) and 2.3.2.14 (the base of drdaeman's patched bootloader); wisp-ota
#      fetch if missing, SHA-256 pinned. Even's firmware never leaves .wisp-cache.
#   2. native-1, stage-0c and native-1's real app (scripts/build_native.sh; the app has the UART1 console
#      back for rung3.py: tests/boot/app/rung3-console.*)
#   3. both Wisp Boot builds with the fault apps and the real app behind them
#      (scripts/build_boot.sh -DWISP_BOOT_TEST_APPS=ON -DWISP_REAL_APP=...): the fallback build in
#      build/wisp-boot, the observe-only one in build/wisp-boot-observe, which must be byte-identical
#      to native-1's (its first 64 KiB are what rung4.md R4-1 compares); and the observe build with
#      -DWISP_BOOT_NOR=OFF (rung4.md W24e: no NOR phase) in build/wisp-boot-observe-nor-off
#   4. tests/boot/rung3.py for every suite on every bootloader (safety.md rule 12: the stock
#      2.4.0.24 and the patched 87e2d4e0... bootloader); each table goes to
#      .wisp-cache/rung3/<bootloader>-<sha8>-<suite>/report.md
#
# WISP_RUNG3_SUITES (default "fallback observe nor-off") and WISP_RUNG3_BOOTLOADERS (default "stock
# patched") narrow it; extra args go to rung3.py (e.g. --only app-hangs cut-after-flag, --list).
source "$(dirname "$0")/lib.sh"
wisp_devshell "$@"
wisp_require_setup

ota="$REPO_ROOT/packages/wisp-ota/dist/cli.js"
if [[ ! -f "$ota" ]]; then
	echo "wisp-fw: build wisp-ota first: pnpm nx run wisp-ota:build" >&2
	exit 1
fi
stock="${WISP_STOCK_VERSION:-2.4.0.24}"
for v in "$stock" 2.3.2.14; do
	if [[ ! -f "$CACHE_DIR/stock/g2-$v.bin" ]]; then
		(cd "$REPO_ROOT" && node "$ota" fetch "$v")
	fi
done

"$APP_DIR/scripts/build_native.sh" native-1 >/dev/null
native="$CACHE_DIR/build/native-1"
# The real app behind Wisp Boot: native-1's app with the UART1 console back (rung3.py follows its
# banner and heartbeats; tests/boot/app/rung3-console.*). The hardware image itself has no console;
# wisp-fw:w18-test native-1 runs that one.
rung3_app="$CACHE_DIR/build/rung3-app"
rm -rf "$rung3_app"
WISP_PANEL=none WISP_BUILD_DIR="$rung3_app" "$APP_DIR/scripts/build.sh" \
	"-DEXTRA_CONF_FILE=$APP_DIR/images/native-1/native-1.conf;$APP_DIR/tests/boot/app/rung3-console.conf" \
	"-DEXTRA_DTC_OVERLAY_FILE=$APP_DIR/images/native-1/native-1.overlay;$APP_DIR/tests/boot/app/rung3-console.overlay" \
	>"$CACHE_DIR/build/rung3-app.log" 2>&1 || {
	tail -n 30 "$CACHE_DIR/build/rung3-app.log" >&2
	exit 1
}
app="$rung3_app/zephyr/zephyr.bin"
"$APP_DIR/scripts/build_boot.sh" -DWISP_BOOT_TEST_APPS=ON -DWISP_REAL_APP="$app"
WISP_BOOT_BUILD_DIR="$CACHE_DIR/build/wisp-boot-observe" "$APP_DIR/scripts/build_boot.sh" \
	-DWISP_BOOT_OBSERVE=ON -DWISP_BOOT_LOG=OFF -DWISP_BOOT_TEST_APPS=ON -DWISP_REAL_APP="$app" -DWISP_STAGE0=ON
WISP_BOOT_BUILD_DIR="$CACHE_DIR/build/wisp-boot-observe-nor-off" "$APP_DIR/scripts/build_boot.sh" \
	-DWISP_BOOT_OBSERVE=ON -DWISP_BOOT_LOG=OFF -DWISP_BOOT_NOR=OFF -DWISP_BOOT_TEST_APPS=ON \
	-DWISP_REAL_APP="$app" -DWISP_STAGE0=ON
"$APP_DIR/scripts/build_native.sh" stage-0c >/dev/null
cmp "$CACHE_DIR/build/wisp-boot-observe/wisp_boot.bin" "$CACHE_DIR/build/stage-0c/boot/wisp_boot.bin" || {
	echo "FAIL: the observe-only Wisp Boot under test differs from stage-0c's" >&2
	exit 1
}
cmp "$CACHE_DIR/build/wisp-boot-observe/native_stage0.bin" "$CACHE_DIR/build/stage-0c/stage-0c.bin" || {
	echo "FAIL: native_stage0.bin differs from stage-0c.bin" >&2
	exit 1
}
cmp "$CACHE_DIR/build/wisp-boot-observe/wisp_boot.bin" "$native/boot/wisp_boot.bin" || {
	echo "FAIL: the observe-only Wisp Boot under test differs from native-1's" >&2
	exit 1
}

status=0
for bl in ${WISP_RUNG3_BOOTLOADERS:-stock patched}; do
	for suite in ${WISP_RUNG3_SUITES:-fallback observe nor-off}; do
		build="$CACHE_DIR/build/wisp-boot"
		[[ "$suite" == observe ]] && build="$CACHE_DIR/build/wisp-boot-observe"
		[[ "$suite" == nor-off ]] && build="$CACHE_DIR/build/wisp-boot-observe-nor-off"
		printf '\n=== rung 3: %s suite, %s bootloader\n' "$suite" "$bl"
		python3 -I "$APP_DIR/tests/boot/rung3.py" --cache "$CACHE_DIR" --boot-build "$build" \
			--stock-version "$stock" --bootloader "$bl" --suite "$suite" "$@" || status=1
	done
done
exit $status
