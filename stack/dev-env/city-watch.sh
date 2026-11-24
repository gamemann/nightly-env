#!/bin/bash
# Cron watchdog for a dev city server (run every minute):  city-watch.sh [profile]   (default games)
# Starts the server when its port is closed, and RESTARTS it when the port is open but it no longer answers
# or its resident memory has reached the leak ceiling. The old check was only "is :3013 listening", which a
# next dev --turbo pinned at its cgroup MemoryMax passes for hours while every request times out or 500s
# (backbone-500: all dev game servers failing report/auth/loadout calls).
# Knobs (env): WATCH_PORT (3013), WATCH_URL, WATCH_FAILS (3 consecutive bad probes), WATCH_TIMEOUT (10 s),
# WATCH_RSS_MB (12000: recycle before the 14G cap makes it thrash), WATCH_STATE_DIR, CITY_SH.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="${1:-games}"
PORT="${WATCH_PORT:-3013}"
URL="${WATCH_URL:-http://127.0.0.1:$PORT/api/content/server/list?limit=1}"
FAILS="${WATCH_FAILS:-3}"
TMO="${WATCH_TIMEOUT:-10}"
RSS_MB="${WATCH_RSS_MB:-12000}"
CITY_SH="${CITY_SH:-$HERE/city.sh}"
STATE="${WATCH_STATE_DIR:-${TMPDIR:-/tmp}}/city-watch-$P.fails"
log() { echo "$(date '+%F %T') city-watch[$P]: $*"; }

listen_pid() { ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2; }
tree_rss_mb() { # resident MB of the listener's whole process group (npm, next, next-server)
    local pid=$1 pgid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
    [ -n "$pgid" ] || return 1
    ps -eo pgid=,rss= 2>/dev/null | awk -v g="$pgid" '$1==g{s+=$2} END{print int(s/1024)}'
}

pid=$(listen_pid)
if [ -z "$pid" ]; then
    rm -f "$STATE"
    log "port $PORT closed, starting"
    exec "$CITY_SH" "$P"
fi

reason=""
if curl -s -o /dev/null -m "$TMO" "$URL"; then
    rm -f "$STATE"
    rss=$(tree_rss_mb "$pid" || echo 0)
    [ "${rss:-0}" -ge "$RSS_MB" ] && reason="resident memory ${rss} MB >= ${RSS_MB} MB (turbopack leak)"
else
    n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$STATE"
    if [ "$n" -ge "$FAILS" ]; then reason="no answer from $URL in ${TMO}s, $n probes in a row"
    else log "probe $n/$FAILS failed"; fi
fi
[ -n "$reason" ] || exit 0
log "restarting: $reason"
rm -f "$STATE"
"$CITY_SH" "$P" --stop
exec "$CITY_SH" "$P"
