#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Create / refresh the pinned west workspace in .wisp-cache/west (see west.yml).
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
