#!/bin/sh
# usage: tools/with-tools.sh <tool>:<nixpkgs attr>... -- <command...>
# Runs the command as is when every tool is on PATH; otherwise, on a Nix
# host, inside `nix shell` with the missing ones.
set -e
missing=""
while [ "$1" != "--" ]; do
  command -v "${1%%:*}" >/dev/null 2>&1 || missing="$missing nixpkgs#${1#*:}"
  shift
done
shift
[ -z "$missing" ] && exec "$@"
command -v nix >/dev/null 2>&1 || { echo "missing:$missing" >&2; exit 127; }
exec nix shell $missing -c "$@"
