#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Boot the built image in Renode (g2emu platform) and print what it writes to UART1.
#
#   scripts/sim.sh [seconds]     run for <seconds> of virtual time (default 10)
#
# Output: the UART1 capture on stdout; the run directory (uart1.txt, renode.log) is printed
# last. Needs a build (pnpm nx run wisp-fw:build). Emulation only — nothing here talks to
# hardware.
source "$(dirname "$0")/lib.sh"
wisp_devshell "$@"

secs="${1:-${WISP_SIM_SECONDS:-10}}"
elf="$BUILD_DIR/zephyr/zephyr.elf"
bin="$BUILD_DIR/zephyr/zephyr.bin"
[[ -f "$elf" && -f "$bin" ]] || {
	echo "wisp-fw: no image at $elf; run: pnpm nx run wisp-fw:build" >&2
	exit 1
}

run_dir="${WISP_SIM_RUN_DIR:-$CACHE_DIR/sim/run-$(date +%Y%m%d-%H%M%S)-$$}"
mkdir -p "$run_dir"
: >"$run_dir/uart1.txt"
export G2_CAPTURE_OUT="$run_dir"

# Initial SP and reset vector, as Wisp Boot hands them over (the app is linked at 0x448000).
read -r sp pc < <(python3 -c 'import struct,sys; print("0x%08x 0x%08x" % struct.unpack_from("<II", open(sys.argv[1],"rb").read(8)))' "$bin")

# Stream the UART while Renode runs.
tail -n +1 -F "$run_dir/uart1.txt" 2>/dev/null &
tail_pid=$!
trap 'kill $tail_pid 2>/dev/null || true' EXIT

status=0
renode --disable-gui --plain --console \
	-e "\$bin=@$bin; \$elf=@$elf; \$sp=$sp; \$pc=$pc; include @$APP_DIR/renode/wisp_g2.resc; emulation RunFor \"$secs\"; quit" \
	>"$run_dir/renode.log" 2>&1 || status=$?

sleep 0.5
kill $tail_pid 2>/dev/null || true
wait $tail_pid 2>/dev/null || true
echo "--- renode exit $status, run dir: $run_dir" >&2
if [[ $status -ne 0 ]]; then
	tail -n 30 "$run_dir/renode.log" >&2
fi
exit $status
