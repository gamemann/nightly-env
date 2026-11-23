#!/usr/bin/env bash
# Attach a screenshot to a nightly queue item: attach-shot.sh <item> <png|jpg> [note]
# Runs `nightly attach` (it downscales to 1280 px, caps 2 MB, keeps the last 20); prints the URL.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: $0 <item> <file.png|jpg> [note]" >&2; exit 2; }
item=$1; file=$2; note=${3:-}
[ -f "$file" ] || { echo "no such file: $file" >&2; exit 1; }
NIGHTLY=${NIGHTLY_BIN:-/home/core/projects/nightly/bin/nightly}
"$NIGHTLY" attach "$item" "$file" --by "${USER:-session}" ${note:+--note "$note"}
