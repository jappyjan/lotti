#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# wisp-fw:boot-test — rung 3 (docs/wisp/safety.md): Wisp Boot in Renode with the REAL Even
# bootloader and the real Wisp app behind it. Emulation only; nothing here talks to hardware.
#
#   1. stock bundles in the git-ignored .wisp-cache/stock/: 2.4.0.24 (the version on Jan's temples,
#      or $WISP_STOCK_VERSION) and 2.3.2.14 (the base of drdaeman's patched bootloader); wisp-ota
#      fetch if missing, SHA-256 pinned. Even's firmware never leaves .wisp-cache.
#   2. native-0 and stage-0 (scripts/build_native.sh): the real app, stage-0 and the observe-only Wisp Boot
#   3. both Wisp Boot builds with the fault apps and the real app behind them
#      (scripts/build_boot.sh -DWISP_BOOT_TEST_APPS=ON -DWISP_REAL_APP=...): the fallback build in
#      build/wisp-boot, the observe-only one in build/wisp-boot-observe, which must be byte-identical
#      to native-0's (its first 64 KiB are what rung4.md R4-1 compares)
#   4. tests/boot/rung3.py for every suite on every bootloader (safety.md rule 12: the stock
#      2.4.0.24 and the patched 87e2d4e0... bootloader); each table goes to
#      .wisp-cache/rung3/<bootloader>-<sha8>-<suite>/report.md
#
# WISP_RUNG3_SUITES (default "fallback observe") and WISP_RUNG3_BOOTLOADERS (default "stock
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

"$APP_DIR/scripts/build_native.sh" native-0 >/dev/null
native="$CACHE_DIR/build/native-0"
app="$native/app/zephyr/zephyr.bin"
"$APP_DIR/scripts/build_boot.sh" -DWISP_BOOT_TEST_APPS=ON -DWISP_REAL_APP="$app"
WISP_BOOT_BUILD_DIR="$CACHE_DIR/build/wisp-boot-observe" "$APP_DIR/scripts/build_boot.sh" \
	-DWISP_BOOT_OBSERVE=ON -DWISP_BOOT_LOG=OFF -DWISP_BOOT_TEST_APPS=ON -DWISP_REAL_APP="$app" -DWISP_STAGE0=ON
"$APP_DIR/scripts/build_native.sh" stage-0 >/dev/null
cmp "$CACHE_DIR/build/wisp-boot-observe/wisp_boot.bin" "$CACHE_DIR/build/stage-0/boot/wisp_boot.bin" || {
	echo "FAIL: the observe-only Wisp Boot under test differs from stage-0's" >&2
	exit 1
}
cmp "$CACHE_DIR/build/wisp-boot-observe/native_stage0.bin" "$CACHE_DIR/build/stage-0/stage-0.bin" || {
	echo "FAIL: native_stage0.bin differs from stage-0.bin" >&2
	exit 1
}
cmp "$CACHE_DIR/build/wisp-boot-observe/wisp_boot.bin" "$native/boot/wisp_boot.bin" || {
	echo "FAIL: the observe-only Wisp Boot under test differs from native-0's" >&2
	exit 1
}
cmp "$CACHE_DIR/build/wisp-boot-observe/native_real.bin" "$native/native-0.bin" || {
	echo "FAIL: native_real.bin differs from native-0.bin" >&2
	exit 1
}

status=0
for bl in ${WISP_RUNG3_BOOTLOADERS:-stock patched}; do
	for suite in ${WISP_RUNG3_SUITES:-fallback observe}; do
		build="$CACHE_DIR/build/wisp-boot"
		[[ "$suite" == observe ]] && build="$CACHE_DIR/build/wisp-boot-observe"
		printf '\n=== rung 3: %s suite, %s bootloader\n' "$suite" "$bl"
		python3 -I "$APP_DIR/tests/boot/rung3.py" --cache "$CACHE_DIR" --boot-build "$build" \
			--stock-version "$stock" --bootloader "$bl" --suite "$suite" "$@" || status=1
	done
done
exit $status
