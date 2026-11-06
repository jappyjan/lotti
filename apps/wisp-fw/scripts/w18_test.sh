#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# wisp-fw:w18-test — W18 emulation proof: drdaeman's patched bootloader (rebuilt by
# apps/wisp-recovery from the git-ignored .wisp-cache) in Renode, driven by the real w18.py host
# code through the WispCaseLink UART2 model. Emulation only; nothing here talks to hardware.
# Needs .wisp-cache/stock/g2-2.3.2.14.bin and g2-2.4.0.24.bin (wisp-ota fetch). Extra args go to
# tests/boot/w18.py (e.g. --only hello recover). The table goes to .wisp-cache/w18/report.md.
source "$(dirname "$0")/lib.sh"
wisp_devshell "$@"
ota="$REPO_ROOT/packages/wisp-ota/dist/cli.js"
for v in 2.3.2.14 2.4.0.24; do
	if [[ ! -f "$CACHE_DIR/stock/g2-$v.bin" ]]; then
		[[ -f "$ota" ]] || { echo "wisp-fw: build wisp-ota first: pnpm nx run wisp-ota:build" >&2; exit 1; }
		(cd "$REPO_ROOT" && node "$ota" fetch "$v")
	fi
done
python3 -I "$APP_DIR/tests/boot/w18.py" --cache "$CACHE_DIR" "$@"
