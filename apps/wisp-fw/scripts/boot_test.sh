#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# wisp-fw:boot-test — rung 3 (docs/wisp/safety.md): Wisp Boot fallback-to-stock in Renode with
# the REAL Even bootloader. Emulation only; nothing here talks to hardware.
#
#   1. stock bundle (2.2.6.10, or $WISP_STOCK_VERSION) in the git-ignored .wisp-cache/stock/
#      (wisp-ota fetch if missing; SHA-256 pinned). Even's firmware never leaves .wisp-cache.
#   2. Wisp Boot + the fault apps (scripts/build_boot.sh -DWISP_BOOT_TEST_APPS=ON), with the
#      image and rule 8 gates
#   3. tests/boot/rung3.py: reference run, fault cases, power cuts along the rescue path;
#      the table goes to .wisp-cache/rung3/report.md
#
# Extra args go to rung3.py (e.g. --only app-hangs cut-after-flag, --list).
source "$(dirname "$0")/lib.sh"
wisp_devshell "$@"
wisp_require_setup

ota="$REPO_ROOT/packages/wisp-ota/dist/cli.js"
if [[ ! -f "$ota" ]]; then
	echo "wisp-fw: build wisp-ota first: pnpm nx run wisp-ota:build" >&2
	exit 1
fi
stock="${WISP_STOCK_VERSION:-2.2.6.10}"
if [[ ! -f "$CACHE_DIR/stock/g2-$stock.bin" ]]; then
	(cd "$REPO_ROOT" && node "$ota" fetch "$stock")
fi
"$APP_DIR/scripts/build_boot.sh" -DWISP_BOOT_TEST_APPS=ON
python3 -I "$APP_DIR/tests/boot/rung3.py" --cache "$CACHE_DIR" \
	--boot-build "${WISP_BOOT_BUILD_DIR:-$CACHE_DIR/build/wisp-boot}" --stock-version "$stock" "$@"
