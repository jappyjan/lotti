#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copy a built native image into apps/wisp-recovery/wisp_w18/data/<image>/, the way native-0's
# reviewed files were committed (W23): the image, the app's ELF and Wisp Boot's ELF after
# `objcopy --strip-debug` (symbols and every loaded section kept, no debug info, no paths), the app's
# map as built, and the build's manifest. Pinning (wisp_w18/pins.py) is a separate, reviewed step.
#
#   scripts/build_native.sh stage-0b && scripts/package_native.sh stage-0b
#
# Build from a clean, committed tree: the app embeds `git describe --dirty`.
source "$(dirname "$0")/lib.sh"
wisp_devshell "$@"

image="${1:?usage: package_native.sh stage-0b}"
src="$CACHE_DIR/build/$image"
dst="$REPO_ROOT/apps/wisp-recovery/wisp_w18/data/$image"
case "$image" in
stage-0b)
	app_elf="$src/boot/stage0.elf"
	app_map="$src/boot/stage0.map"
	;;
*)
	echo "wisp-fw: package_native.sh knows stage-0b only (native-0 and stage-0 are pinned as reviewed)" >&2
	exit 1
	;;
esac
[[ -f "$src/$image.bin" && -f "$src/manifest.json" ]] || {
	echo "wisp-fw: build it first: scripts/build_native.sh $image" >&2
	exit 1
}
mkdir -p "$dst"
cp "$src/$image.bin" "$dst/$image.bin"
cp "$src/manifest.json" "$dst/manifest.json"
cp "$app_map" "$dst/$(basename "$app_map")"
arm-none-eabi-objcopy --strip-debug "$app_elf" "$dst/$(basename "$app_elf")"
arm-none-eabi-objcopy --strip-debug "$src/boot/wisp_boot.elf" "$dst/wisp_boot.elf"
(cd "$dst" && sha256sum ./*.bin ./*.elf ./*.map ./manifest.json)
