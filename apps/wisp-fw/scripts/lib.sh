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

# Wisp's patches on the pinned fork (third_party/ambiq/patches/, safety rule 8). The file name
# says which west project a patch belongs to: <project>-NNNN-*.patch.
PATCH_DIR="$APP_DIR/third_party/ambiq/patches"
wisp_patch_target() {
	case "$(basename "$1")" in
	zephyr-*) echo "$ZEPHYR_BASE" ;;
	hal_ambiq-*) echo "$WEST_TOP/modules/hal/ambiq" ;;
	*)
		echo "wisp-fw: no west project for patch $1" >&2
		return 1
		;;
	esac
}

# Applies every patch that is not applied yet; fails if one applies neither way.
wisp_apply_patches() {
	local p dir
	for p in "$PATCH_DIR"/*.patch; do
		dir="$(wisp_patch_target "$p")"
		if git -C "$dir" apply --reverse --check "$p" 2>/dev/null; then
			echo "patch already applied: $(basename "$p")"
		elif git -C "$dir" apply --check "$p"; then
			git -C "$dir" apply "$p"
			echo "patch applied: $(basename "$p")"
		else
			echo "wisp-fw: $(basename "$p") does not apply to $dir (pin moved? see third_party/ambiq/README.md)" >&2
			return 1
		fi
	done
}
