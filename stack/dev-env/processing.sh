#!/bin/bash
# website-processing (the landing and legal pages) for one profile: :3003 default, :3014 games, :3015 claude.
#   ~/stack/dev-env/processing.sh [default|games|claude] [--fg | --stop | --status]
# It reads no database; the profile only decides its port and which site (PUBLIC_URL, PUBLIC_CITY_URL) it links to.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/profile.sh"
load_profile "${1:-default}"
MODE="${2:-}"
NAME="processing-$PROFILE"
case "$MODE" in
    --stop) stop_port "$NAME" "$PROCESSING_PORT"; exit ;;
    --status) port_busy "$PROCESSING_PORT" && echo "$NAME: up on :$PROCESSING_PORT (pid $(port_pid "$PROCESSING_PORT"))" || echo "$NAME: down"; exit ;;
esac
port_busy "$PROCESSING_PORT" && { echo "$NAME: :$PROCESSING_PORT is already in use (pid $(port_pid "$PROCESSING_PORT"))" >&2; exit 1; }
export PUBLIC_URL="$SITE_URL" PUBLIC_CITY_URL="$SITE_URL" ASTRO_DEV_BACKGROUND=0  # see dev.sh for the astro flag
CMD=(npm run dev -- --host 0.0.0.0 --port "$PROCESSING_PORT")
# astro allows one tracked dev server per checkout; a profile runs beside the default one, untracked
[ "$PROFILE" = default ] || CMD+=(--ignore-lock)
if [ "$MODE" = --fg ]; then cd "$PROCESSING_DIR" && exec "${CMD[@]}"; fi
start_bg "$NAME" "$PROCESSING_DIR" "${CMD[@]}"
wait_http "$NAME" "http://127.0.0.1:$PROCESSING_PORT/" 120
