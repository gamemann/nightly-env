#!/usr/bin/env bash
# Attach a screenshot to a nightly queue item on dev01: attach-shot.sh <item> <png|jpg> [note]
# scp to a temp path, run `nightly attach` there (it downscales to 1280 px, caps 2 MB, keeps the last 20), print the URL.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: $0 <item> <file.png|jpg> [note]" >&2; exit 2; }
item=$1; file=$2; note=${3:-}
[ -f "$file" ] || { echo "no such file: $file" >&2; exit 1; }
dir=$(ssh -i ~/.ssh/dev01 dev01 mktemp -d)
tmp=$dir/$(basename "$file")
trap 'ssh -i ~/.ssh/dev01 dev01 rm -rf "$dir"' EXIT
scp -q -i ~/.ssh/dev01 "$file" "dev01:$tmp"
ssh -i ~/.ssh/dev01 dev01 ~/stack/nightly/bin/nightly attach "$(printf %q "$item")" "$(printf %q "$tmp")" --by "${USER:-session}" ${note:+--note "$(printf %q "$note")"}
