# SPDX-License-Identifier: MIT
# Shared by the wisp-fw scripts. Source it; don't run it.
#
# Re-executes the calling script inside the flake's devShell (gcc-arm-embedded, west, cmake,
# ninja, dtc, renode) unless it already runs there, and sets the workspace paths. Nothing
# needs sudo; everything fetched lives under the git-ignored .wisp-cache/.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/../.." && pwd)"
CACHE_DIR="${WISP_CACHE_DIR:-$REPO_ROOT/.wisp-cache}"
WEST_TOP="$CACHE_DIR/west"
BUILD_DIR="${WISP_BUILD_DIR:-$CACHE_DIR/build/wisp-fw}"
export ZEPHYR_BASE="$WEST_TOP/zephyr"

wisp_devshell() {
	if [[ "${WISP_FW_DEVSHELL:-}" != 1 ]]; then
		command -v nix >/dev/null || {
			echo "wisp-fw: needs nix (flake devShell in apps/wisp-fw)" >&2
			exit 1
		}
		exec nix develop "$APP_DIR" --command "$0" "$@"
	fi
}

wisp_require_setup() {
	[[ -f "$ZEPHYR_BASE/VERSION" ]] || {
		echo "wisp-fw: west workspace missing; run: pnpm nx run wisp-fw:setup" >&2
		exit 1
	}
}
