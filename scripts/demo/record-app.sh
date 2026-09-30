#!/bin/sh
# record-app.sh <frames-dir> <folder> [seconds]: runs the debug G8r build
# with G8R_RECORD, without activating it, and a neutral zsh prompt.
# Extra env (G8R_DEBUG_CD, G8R_RECORD_MAP_AT) passes through.
set -eu
out="$1"; folder="$2"; secs="${3:-8}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
bin="$(swift build --package-path "$root" --show-bin-path)/G8r"
z="$(mktemp -d)"
printf "PROMPT='%%F{green}%%1~%%f %%# '\n" > "$z/.zshrc"
sock="$HOME/.g8r/rec$$.sock"
rm -rf "$out"
ZDOTDIR="$z" G8R_RECORD="$out" G8R_RECORD_SECONDS="$secs" G8R_COLLECTOR="$sock" "$bin" "$folder" >/dev/null 2>&1 &
pid=$!
sleep "$secs"; sleep 1
kill "$pid"; rm -rf "$z" "$sock"
