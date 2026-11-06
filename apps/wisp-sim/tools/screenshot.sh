#!/bin/sh
# Renders the viewer headless with the hello example running (three taps in)
# into docs/viewer.png. Needs a built sim (nx run wisp-sim:build) and Chromium
# (fetched with nix when missing).
set -e
cd "$(dirname "$0")/.."
port=${PORT:-8399}
out=${1:-docs/viewer.png}
node dist/src/main.js --port "$port" >/dev/null &
sim=$!
trap 'kill $sim $hello 2>/dev/null' EXIT
sleep 1
node dist/examples/hello.js "ws://127.0.0.1:$port/link" >/dev/null &
hello=$!
sleep 1.5
for _ in 1 2 3; do
  curl -s -XPOST "http://127.0.0.1:$port/api/input" -d '{"type":"gesture","lens":2,"kind":1}'
  sleep 0.05
done
sleep 0.5
shot="chromium --headless=new --no-sandbox --disable-gpu --hide-scrollbars --window-size=1400,820 \
  --virtual-time-budget=3000 --screenshot=$out http://127.0.0.1:$port/"
if command -v chromium >/dev/null; then
  $shot
else
  # env -u: a host LD_LIBRARY_PATH can pull in a mismatched glibc
  nix shell nixpkgs#chromium -c env -u LD_LIBRARY_PATH sh -c "$shot"
fi 2>/dev/null
echo "wrote $out"
