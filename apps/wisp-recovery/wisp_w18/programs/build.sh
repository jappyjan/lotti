#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Builds the W18 RAM programs of this repository (feed, dump_fed, recover_fed) into ../data/ and
# prints their SHA-256, which wisp_w18/pins.py pins. docs/wisp/recovery.md, "The temple's
# watchdog". Nothing here talks to hardware.
#
# Same compiler, flags and link checks as drdaeman's Makefile (g2-bootloader-patch @ 1d22097) for
# his examples, and the nixpkgs revision his flake.lock pins (clang 21.1.8). With these, his own
# checksum.c, dump.c and recover.c rebuild to the pinned checksum.bin, dump.bin and recover.bin
# byte for byte: `build.sh --check-upstream <his checkout>` shows it.
#
#   apps/wisp-recovery/wisp_w18/programs/build.sh            build into ../data/, print hashes
#   apps/wisp-recovery/wisp_w18/programs/build.sh --verify   build into a temp dir, compare with ../data/
set -euo pipefail

NIXPKGS="github:NixOS/nixpkgs/c59305bab2065cfecc4944690d9eedbb56f3a9fa"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$HERE/../data"
PROGRAMS=(feed dump_fed recover_fed)

if [[ "${WISP_PROGRAMS_SHELL:-}" != 1 ]]; then
	exec env WISP_PROGRAMS_SHELL=1 nix shell "$NIXPKGS#llvmPackages_21.clang-unwrapped" \
		"$NIXPKGS#llvmPackages_21.lld" "$NIXPKGS#llvmPackages_21.llvm" --command "$0" "$@"
fi

CFLAGS=(--target=arm-none-eabi -mthumb -Oz -ffreestanding -fno-builtin -fno-jump-tables
	-fno-unwind-tables -fno-asynchronous-unwind-tables -Wall -Wextra -Werror -fropi
	-mcpu=cortex-m4 -mfpu=fpv4-sp-d16 -mfloat-abi=softfp -ffp-contract=off -fomit-frame-pointer
	-mno-unaligned-access -mrestrict-it)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# build <source dir> <name> <output dir>: one program, linked at 0 and again at 0x1000; the two
# images must be identical (position independent: the loader runs it from a stack buffer).
build() {
	local src="$1" name="$2" out="$3"
	clang "${CFLAGS[@]}" -I"$src" -I"$HERE" -c "$src/$name.c" -o "$work/$name.o"
	ld.lld -O0 --entry=0 -T "$HERE/payload.ld" "$work/$name.o" -o "$work/$name.elf"
	llvm-objcopy -O binary --only-section=.text --only-section=.rodata "$work/$name.elf" "$out/$name.bin"
	ld.lld -O0 --entry=0 --defsym=IMAGE_BASE=0x1000 -T "$HERE/payload.ld" "$work/$name.o" -o "$work/$name.moved.elf"
	llvm-objcopy -O binary --only-section=.text --only-section=.rodata "$work/$name.moved.elf" "$work/$name.moved.bin"
	cmp "$out/$name.bin" "$work/$name.moved.bin"
}

clang --version | head -1
case "${1:-}" in
--check-upstream)
	upstream="${2:?usage: build.sh --check-upstream <g2-bootloader-patch checkout at 1d22097>}"
	for name in checksum dump recover; do
		build "$upstream/src/examples" "$name" "$work"
		echo "$(sha256sum "$work/$name.bin" | cut -d' ' -f1)  $name.bin (upstream source)"
		cmp "$work/$name.bin" "$DATA/$name.bin"
	done
	echo "upstream programs rebuild byte for byte"
	;;
--verify)
	for name in "${PROGRAMS[@]}"; do
		build "$HERE" "$name" "$work"
		cmp "$work/$name.bin" "$DATA/$name.bin"
		echo "$(sha256sum "$work/$name.bin" | cut -d' ' -f1)  $name.bin ($(stat -c %s "$work/$name.bin") B) matches data/"
	done
	;;
"")
	for name in "${PROGRAMS[@]}"; do
		build "$HERE" "$name" "$DATA"
		echo "$(sha256sum "$DATA/$name.bin" | cut -d' ' -f1)  $name.bin ($(stat -c %s "$DATA/$name.bin") B)"
	done
	;;
*)
	echo "usage: build.sh [--verify | --check-upstream <dir>]" >&2
	exit 2
	;;
esac
