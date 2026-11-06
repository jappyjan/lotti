#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Create / refresh the pinned west workspace in .wisp-cache/west (see west.yml), then apply
# Wisp's patches to it (third_party/ambiq/patches/: the EM9305 driver never writes NVM).
source "$(dirname "$0")/lib.sh"
wisp_devshell "$@"

mkdir -p "$WEST_TOP/manifest"
cp "$APP_DIR/west.yml" "$WEST_TOP/manifest/west.yml"
if [[ ! -d "$WEST_TOP/.west" ]]; then
	(cd "$WEST_TOP" && west init -l manifest)
fi
# --narrow + depth 1: fetch only the pinned SHAs, not every branch of every repo.
(cd "$WEST_TOP" && west update --narrow --fetch-opt=--depth=1)
(cd "$WEST_TOP" && west list -f '{name:16} {revision} {url}')
wisp_apply_patches
