#!/bin/bash
# Proves the dev chain end to end: panel servers on this VM -> A2S answers -> enrolled and listed on tmcdev.net -> dev CDN
# packs hash-check -> (with --browser) the web player loads and connects. See ~/docs/dev-environment.md.
#   tools/dev-env-check.sh [--profile default|games|claude] [--browser] [--no-cdn]
# The profile is the dev site the servers are provisioned for (devenv.py provision --profile); default tmcdev.net.
# Exit status is the number of failed checks.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="$HERE/dev-env"; SITE=https://tmcdev.net; CDN=https://dev.dotgames.org/content; NODE_IP=10.50.0.119
BROWSER=0; CDN_CHECK=1; PROFILE=default
while [ $# -gt 0 ]; do case "$1" in --browser) BROWSER=1 ;; --no-cdn) CDN_CHECK=0 ;; --profile) PROFILE=${2:-}; shift ;; *) echo "unknown: $1"; exit 2 ;; esac; shift; done
case "$PROFILE" in default) ;; games) SITE=https://games.tmcdev.net ;; claude) SITE=https://claude.tmcdev.net ;; *) echo "unknown profile: $PROFILE"; exit 2 ;; esac
# The wss proxy for every profile is tmcdev.net:61xx on dev01, so a listed host is the node or tmcdev.net.
WSS_HOST=tmcdev.net
fails=0; ok() { echo "  ok    $*"; }; bad() { echo "  FAIL  $*"; fails=$((fails + 1)); }

echo "panel (this VM: panel.tmcdev.net, node tmc-dev)"
python3 "$DEV/devenv.py" list | sed 's/^/        /'
mapfile -t RUNNING < <(python3 "$DEV/devenv.py" list | awk '/state=running/ {print $1" "$5}' | sed 's/port=//')
[ "${#RUNNING[@]}" -gt 0 ] && ok "${#RUNNING[@]} dev server(s) running" || bad "no dev server is running"

echo "A2S and the dev site listing"
for line in "${RUNNING[@]}"; do
    repo=${line% *}; port=${line#* }; NODE_IP=$(python3 "$DEV/devenv.py" ip "$repo")
    name=$(python3 - "$NODE_IP" "$port" <<'EOF'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
q = b"\xff\xff\xff\xffTSource Engine Query\x00"; a = (sys.argv[1], int(sys.argv[2]))
try:
    s.sendto(q, a); d = s.recv(1400)
    if d[4:5] == b"A": s.sendto(q + d[5:9], a); d = s.recv(1400)
    print(d[6:].split(b"\x00")[0].decode(errors="replace"))
except OSError: print("")
EOF
)
    [ -n "$name" ] && ok "$repo :$port answers A2S as \"$name\"" || { bad "$repo :$port does not answer A2S"; continue; }
    # A row with useHostName lists the site host, whose nginx proxies the wss port to the node.
    listed=$(curl -s "$SITE/api/content/server/list?limit=200" | python3 -c "import json,sys; print(sum(1 for s in json.load(sys.stdin)['data'] if s.get('port')==$port and str(s.get('host')) in ('$NODE_IP', '$WSS_HOST')))" 2>/dev/null)
    [ "${listed:-0}" -gt 0 ] && ok "$repo :$port is in the $SITE server list" || bad "$repo :$port is not in the $SITE server list (not enrolled, not scanned online yet, or hidden)"
    # Only whether a token is there is printed, never the token.
    sudo cat "/var/lib/pterodactyl/volumes/$(python3 "$DEV/devenv.py" uuid "$repo")/data/listing.json" 2>/dev/null \
        | python3 -c "import json,sys; sys.exit(0 if str(json.load(sys.stdin).get('integration_token','')).strip() else 1)" 2>/dev/null \
        && ok "$repo holds an enrolled integration token" || bad "$repo has no integration token in data/listing.json (enrollment)"
done

if [ "$CDN_CHECK" = 1 ]; then
    echo "dev CDN ($CDN), hash-checked into a temp dir"
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    for lock in "$DEV"/locks/*.lock.json; do
        [ -e "$lock" ] || { bad "no dev locks in $DEV/locks"; break; }
        n=$(basename "$lock" .lock.json); mkdir -p "$tmp/$n"
        if timeout 1800 ~/godot/dot-bootstrap/tools/fetch_lock.sh "$lock" --root "$tmp/$n" --packs "$tmp/$n" --cfg /nonexistent --from "$CDN" >"$tmp/$n.log" 2>&1; then
            ok "$n: $(find "$tmp/$n" -type f | wc -l) files from the dev CDN"
        else
            bad "$n: fetch_lock failed: $(grep -m1 -iE 'error|mismatch|fail' "$tmp/$n.log")"
        fi
    done
fi

if [ "$BROWSER" = 1 ]; then
    echo "web player (Playwright on dev02, through heavy)"
    SESSION=(); [ -f "$HOME/.config/dot/session-dev-$PROFILE" ] && SESSION=(--session "$HOME/.config/dot/session-dev-$PROFILE")
    heavy -- timeout 600 node "$DEV/web_check.mjs" "$DEV/web-check.png" --site "$SITE" "${SESSION[@]}" && ok "web player check (screenshot $DEV/web-check.png)" || bad "web player check failed"
fi

echo "$fails failed"
exit "$fails"
