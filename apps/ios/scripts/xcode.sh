#!/usr/bin/env bash
# Builds, tests and runs the Lotti iOS app from the command line (used by the Nx targets).
#   xcode.sh build        build for the iOS Simulator, unsigned
#   xcode.sh test         run unit tests on an available iPhone simulator
#   xcode.sh run-device   build, install and launch on a connected iPhone, streaming its console
#                         (set LOTTI_DEVICE to a device id to pick one; default: first paired iPhone)
set -euo pipefail
cd "$(dirname "$0")/.."

# One build folder per action: Nx runs build and test in parallel, and xcodebuild locks its folder.
DERIVED=../../tmp/DerivedData/ios-${1:-none}
COMMON=(-project Lotti.xcodeproj -scheme Lotti -derivedDataPath "$DERIVED")

case "${1:-}" in
  build)
    xcodebuild build "${COMMON[@]}" -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet
    ;;
  test)
    sim=$(xcrun simctl list devices available | grep -m1 -E '^\s+iPhone' | grep -oE '[0-9A-F-]{36}')
    xcodebuild test "${COMMON[@]}" -destination "id=$sim" CODE_SIGNING_ALLOWED=NO -quiet
    ;;
  run-device)
    device=${LOTTI_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ && !/unavailable/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}
    [[ -n "$device" ]] || { echo "No paired iPhone found. Connect it and trust this Mac." >&2; exit 1; }
    xcodebuild build "${COMMON[@]}" -configuration Debug -destination "id=$device" -allowProvisioningUpdates -quiet
    xcrun devicectl device install app --device "$device" "$DERIVED/Build/Products/Debug-iphoneos/Lotti.app"
    xcrun devicectl device process launch --device "$device" --console --terminate-existing de.janjaap.lotti
    ;;
  *)
    echo "usage: $0 build|test|run-device" >&2
    exit 2
    ;;
esac
