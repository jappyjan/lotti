#!/usr/bin/env bash
# Compiles the mascot art (apps/ios/Lotti/Mascot/Art/*.swift) with main.swift into a macOS
# command-line tool and renders preview PNGs into the given directory. Needs only the Swift
# command line tools (no Xcode).
#   render.sh <output-dir>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
art="$here/../../Lotti/Mascot/Art"
out="${1:?usage: render.sh <output-dir>}"
build="${TMPDIR:-/tmp}/lotti-render-mascot"
mkdir -p "$build" "$out"
swiftc -parse-as-library -swift-version 6 -O \
  -target "$(uname -m)-apple-macos14" \
  "$art"/*.swift "$here/main.swift" \
  -o "$build/render-mascot"
"$build/render-mascot" "$out"
