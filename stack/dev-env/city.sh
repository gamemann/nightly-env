#!/bin/bash
# website-city dev server for one profile: tmc_dev on :3002, dev_games on :3013 or tmc_claude on :3012.
#   ~/stack/dev-env/city.sh [default|games|claude] [--fg | --stop | --status]
# Background by default (log in ~/stack/.dev-logs/city-<profile>.log). Each profile has its own NEXT_DIST_DIR,
# because two next dev servers sharing one .next corrupt each other. No worker: it would open Spy's :4322 twice.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/profile.sh"
load_profile "${1:-default}"
MODE="${2:-}"
NAME="city-$PROFILE"
# city-games under next dev --turbo reaches 6+ GB after a few requests and grows ~40 MB/request; 8G got it OOM-killed.
[ "$PROFILE" = games ] && DEV_MEM_MAX="${DEV_MEM_MAX:-14G}"
case "$MODE" in
    --stop) stop_port "$NAME" "$CITY_PORT"; exit ;;
    --status) port_busy "$CITY_PORT" && echo "$NAME: up on :$CITY_PORT (pid $(port_pid "$CITY_PORT")), db $DB_NAME, $SITE_URL" || echo "$NAME: down"; exit ;;
esac
port_busy "$CITY_PORT" && { echo "$NAME: :$CITY_PORT is already in use (pid $(port_pid "$CITY_PORT"))" >&2; exit 1; }
echo "$NAME: db $DB_NAME, $SITE_URL -> 127.0.0.1:$CITY_PORT, dist ${NEXT_DIST_DIR:-.next}"
CMD=(npm run dev -- --hostname 0.0.0.0 --port "$CITY_PORT")
if [ "$MODE" = --fg ]; then cd "$CITY_DIR" && exec "${CMD[@]}"; fi
start_bg "$NAME" "$CITY_DIR" "${CMD[@]}"
wait_http "$NAME" "http://127.0.0.1:$CITY_PORT/api/content/server/list?limit=1" 180
