#!/usr/bin/env bash
# Builds, tests and runs the Lotti iOS app from the command line (used by the Nx targets).
#   xcode.sh build        build for the iOS Simulator, unsigned
#   xcode.sh test         run unit tests on an available iPhone simulator
#   xcode.sh run-device   build, install and launch on a connected iPhone, streaming its console
#                         (set LOTTI_DEVICE to a device id to pick one; default: first paired iPhone;
#                         extra arguments go to the app, e.g. `run-device --eval apple`)
set -euo pipefail
cd "$(dirname "$0")/.."

# wisp-ota for JavaScriptCore (packages/wisp-ota-jsc, built by Nx before these targets). The app
# bundle gets wisp-ota.js; the fake stock temple only goes into Simulator builds (tests and the
# simulated temple), never into a device build.
JS_DIST=../../packages/wisp-ota-jsc/dist
JS_DEST=Lotti/Wisp/Generated
wisp_js() {
  [[ -f "$JS_DIST/wisp-ota.js" ]] || (cd ../.. && pnpm nx run wisp-ota-jsc:bundle)
  mkdir -p "$JS_DEST"
  cp "$JS_DIST/wisp-ota.js" "$JS_DEST/"
  if [[ "$1" == simulator ]]; then
    cp "$JS_DIST/wisp-ota-fake-temple.js" "$JS_DEST/"
  else
    rm -f "$JS_DEST/wisp-ota-fake-temple.js"
  fi
}

# One build folder per action: Nx runs build and test in parallel, and xcodebuild locks its folder.
DERIVED=../../tmp/DerivedData/ios-${1:-none}
COMMON=(-project Lotti.xcodeproj -scheme Lotti -derivedDataPath "$DERIVED")

case "${1:-}" in
  build)
    wisp_js simulator
    xcodebuild build "${COMMON[@]}" -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet
    ;;
  test)
    wisp_js simulator
    sim=$(xcrun simctl list devices available | grep -m1 -E '^\s+iPhone' | grep -oE '[0-9A-F-]{36}')
    xcodebuild test "${COMMON[@]}" -destination "id=$sim" CODE_SIGNING_ALLOWED=NO -quiet
    ;;
  run-device)
    device=${LOTTI_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ && !/unavailable/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}
    [[ -n "$device" ]] || { echo "No paired iPhone found. Connect it and trust this Mac." >&2; exit 1; }
    wisp_js device
    xcodebuild build "${COMMON[@]}" -configuration Debug -destination "id=$device" -allowProvisioningUpdates -quiet
    app="$DERIVED/Build/Products/Debug-iphoneos/Lotti.app"
    if [[ -e "$app/wisp-ota-fake-temple.js" ]]; then
      echo "refusing to install: the fake stock temple is in the device build" >&2
      exit 1
    fi
    xcrun devicectl device install app --device "$device" "$DERIVED/Build/Products/Debug-iphoneos/Lotti.app"
    xcrun devicectl device process launch --device "$device" --console --terminate-existing de.janjaap.lotti "${@:2}"
    ;;
  *)
    echo "usage: $0 build|test|run-device" >&2
    exit 2
    ;;
esac
