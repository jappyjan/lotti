#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the wisp_g2 image (WISP_BOARD picks another board, e.g. native_sim/native/64 for the
# end-to-end BLE test). Extra args go to CMake.
# Output: .wisp-cache/build/wisp-fw/zephyr/zephyr.{elf,bin,map}. The post-build gates
# (check_image.py, check_rule8.py) run as part of the link.
source "$(dirname "$0")/lib.sh"
wisp_devshell "$@"
wisp_require_setup

west build --pristine=auto -b "${WISP_BOARD:-wisp_g2}" -s "$APP_DIR" -d "$BUILD_DIR" -- "$@"
