#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# wisp-fw:build-native — a whole native image: Wisp Boot padded to 64 KiB + the Wisp app at
# 0x448000, exactly what install-wisp would write at 0x438000 (docs/wisp/rung4.md §2, §3).
#
#   scripts/build_native.sh native-1
#   scripts/build_native.sh stage-0b
#
# native-1 (rung4.md W25): the observe-only Wisp Boot (no NOR or MRAM write code, always run-app, no
# UART1 log) and the app with images/native-1/ (no console, the panel through the gated rail
# switches, PMIC configuration untouched: cmake/hwimage.cmake). native-0 (W22) was built the same
# way with images/native-0/ and is pinned as built at 8374f9a; this tree no longer builds it. Every gate
# runs on its part: Wisp Boot (check_image, rule 8, no MRAM write), the app (check_image --part app,
# rule 8, no MRAM write, all in its build), the combined image (layout, both vector tables, Wisp
# Boot's slot byte for byte) and wisp-ota's own rule-3 checks (pack-main). Nothing is pinned here:
# pinning is W23, after review.
#
# stage-0b (rung4.md W24d): the same observe-only Wisp Boot and the bare-metal app of src/stage0/
# (no Zephyr), built with Wisp Boot's CMake project. Its gates: check_image --part app, rule 8 and
# the no-MRAM-write gate over the app, then the same combine, check_native and pack-main. (stage-0,
# pinned at W24b-0, is the build of commit 9bfac4d with `stage-0`; this tree builds stage-0b.)
#
# Output in .wisp-cache/build/<image>/: <image>.bin, <image>.evenota, manifest.json (SHA-256 of the
# image, both ELFs and maps, Wisp Boot's binary and its 64 KiB slot), boot/ and app/ build dirs.
source "$(dirname "$0")/lib.sh"
wisp_devshell "$@"
wisp_require_setup

image="${1:?usage: build_native.sh native-1|stage-0b}"
case "$image" in
native-1)
	boot_args=(-DWISP_BOOT_OBSERVE=ON -DWISP_BOOT_LOG=OFF)
	;;
native-0 | stage-0)
	echo "wisp-fw: $image is pinned as built (native-0 at 8374f9a, stage-0 at 9bfac4d; apps/wisp-recovery/wisp_w18/data/);" \
		"build it from that commit: this tree builds native-1 and stage-0b" >&2
	exit 1
	;;
stage-0b)
	boot_args=(-DWISP_BOOT_OBSERVE=ON -DWISP_BOOT_LOG=OFF -DWISP_STAGE0=ON)
	;;
*)
	echo "wisp-fw: unknown native image '$image' (known: native-1, stage-0b)" >&2
	exit 1
	;;
esac
cfg="$APP_DIR/images/$image"
out="$CACHE_DIR/build/$image"
ota="$REPO_ROOT/packages/wisp-ota/dist/cli.js"
[[ -f "$ota" ]] || {
	echo "wisp-fw: build wisp-ota first: pnpm nx run wisp-ota:build" >&2
	exit 1
}
mkdir -p "$out"

echo "=== $image: Wisp Boot (${boot_args[*]})"
rm -rf "$out/boot"
WISP_BOOT_BUILD_DIR="$out/boot" "$APP_DIR/scripts/build_boot.sh" "${boot_args[@]}"

if [[ "$image" == stage-0b ]]; then
	b="$out/boot"
	echo "=== $image: app gates (bare metal, $b/stage0.elf)"
	python3 -I "$APP_DIR/scripts/check_image.py" --elf "$b/stage0.elf" --bin "$b/stage0.bin" --part app
	python3 -I "$APP_DIR/scripts/check_rule8.py" --elf "$b/stage0.elf" --bin "$b/stage0.bin" \
		--map "$b/stage0.map" --config "$b/no-kconfig.config" \
		--compile-commands "$b/compile_commands.json" --hal "$WEST_TOP/modules/hal/ambiq"
	python3 -I "$APP_DIR/scripts/check_no_mram_write.py" --elf "$b/stage0.elf" --bin "$b/stage0.bin" \
		--map "$b/stage0.map"
	echo "=== $image: combine"
	cmake -DBOOT="$b/wisp_boot.bin" -DAPP="$b/stage0.bin" -DOUT="$out/$image.bin" \
		-P "$APP_DIR/tests/boot/app/combine.cmake"
	python3 -I "$APP_DIR/scripts/check_native.py" --image "$out/$image.bin" --boot "$b/wisp_boot.bin" \
		--app "$b/stage0.bin" --manifest "$out/manifest.json" --name "$image" \
		--file boot_elf="$b/wisp_boot.elf" --file boot_map="$b/wisp_boot.map" \
		--file app_elf="$b/stage0.elf" --file app_map="$b/stage0.map" \
		--boot-elf "$b/wisp_boot.elf" --observe --bare-app-elf "$b/stage0.elf"
	echo "=== $image: wisp-ota pack-main (its own rule-3 guards)"
	(cd "$REPO_ROOT" && node "$ota" pack-main "$out/$image.bin" --version 0.0.0.0 -o "$out/$image.evenota")
	echo "=== $image: $out/$image.bin"
	cat "$out/manifest.json"
	exit 0
fi

echo "=== $image: app"
rm -rf "$out/app" # from scratch: a cached configure would miss a changed overlay or .conf
WISP_PANEL=none WISP_BUILD_DIR="$out/app" "$APP_DIR/scripts/build.sh" \
	"-DEXTRA_CONF_FILE=$cfg/$image.conf" "-DEXTRA_DTC_OVERLAY_FILE=$cfg/$image.overlay" \
	>"$out/app-build.log" 2>&1 || {
	tail -n 40 "$out/app-build.log" >&2
	echo "FAIL: $image app build (log: $out/app-build.log)" >&2
	exit 1
}
grep -E "^(check_|-- Wisp hardware image gate)" "$out/app-build.log"
grep -q "^-- Wisp hardware image gate: " "$out/app-build.log" || {
	echo "FAIL: $image was built without the hardware image gate (CONFIG_WISP_HW_IMAGE)" >&2
	exit 1
}

echo "=== $image: combine"
cmake -DBOOT="$out/boot/wisp_boot.bin" -DAPP="$out/app/zephyr/zephyr.bin" -DOUT="$out/$image.bin" \
	-P "$APP_DIR/tests/boot/app/combine.cmake"
python3 -I "$APP_DIR/scripts/check_native.py" --image "$out/$image.bin" --boot "$out/boot/wisp_boot.bin" \
	--app "$out/app/zephyr/zephyr.bin" --manifest "$out/manifest.json" --name "$image" \
	--file boot_elf="$out/boot/wisp_boot.elf" --file boot_map="$out/boot/wisp_boot.map" \
	--file app_elf="$out/app/zephyr/zephyr.elf" --file app_map="$out/app/zephyr/zephyr.map" \
	--app-config "$out/app/zephyr/.config" --boot-elf "$out/boot/wisp_boot.elf" --observe

echo "=== $image: wisp-ota pack-main (its own rule-3 guards)"
(cd "$REPO_ROOT" && node "$ota" pack-main "$out/$image.bin" --version 0.0.0.0 -o "$out/$image.evenota")
echo "=== $image: $out/$image.bin"
cat "$out/manifest.json"
