#!/usr/bin/env bash
# web_check.mjs on staging02 (the desktop) instead of dev02: Playwright is a browser on the CPU, so it belongs with the suites.
# Same arguments as web_check.mjs; the screenshots come back next to OUT.png. WEB_CHECK_LOCAL=1 runs on this machine.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
if [[ -n ${WEB_CHECK_LOCAL:-} ]]; then exec node "$HERE/web_check.mjs" "$@"; fi
KEY=${GPU_KEY:-$HOME/.ssh/gpu-laptop}; HOST=gamedev@staging02.deacon.internal
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "$HOST")
out=/tmp/web-check.png; args=()
for a in "$@"; do if [[ $a == *.png ]]; then out=$a; args+=("$(basename "$a")"); else args+=("$a"); fi; done
rsync -az -e "ssh -i $KEY -o BatchMode=yes" "$HERE/web_check.mjs" "$HOST:wc/" || exit 75
[[ -n ${SESSION_FILE:-} ]] && true
"${SSH[@]}" "cd ~/wc && PWCORE=\$HOME/pwcore/node_modules/playwright-core/index.js CHROME=/usr/bin/google-chrome timeout 600 env WC_REQS=1 WC_GREP=\"${WC_GREP:-}\" node web_check.mjs $(printf '%q ' "${args[@]}")"; rc=$?
base=$(basename "${out%.png}"); mkdir -p "$(dirname "$out")"
rsync -az -e "ssh -i $KEY -o BatchMode=yes" "$HOST:wc/$base*.png" "$(dirname "$out")/" 2>/dev/null
exit $rc
