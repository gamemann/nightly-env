#!/bin/bash
# The web half of a dev profile's game stack on dev01: database upkeep, then city and processing.
#   ~/stack/dev-env/games-stack.sh [games|claude|default] [--db] [--stop | --status]
#   --db   prisma db push, db:idx:sync, db:mv:sync, db:ch:sync and (games) db:seed:dev-games before starting.
#          Refused for default: tmc_dev is shared, its schema is pushed by whoever changes it.
# The game servers are on x-gs01, driven from dev02: ~/godot/tools/dev-env/servers.sh <profile> ...
set -uo pipefail
HERE="$(dirname "${BASH_SOURCE[0]}")"
. "$HERE/profile.sh"
P="${1:-games}"; shift || true
DB=0; MODE=""
for a in "$@"; do case "$a" in --db) DB=1 ;; --stop|--status) MODE=$a ;; *) echo "unknown: $a" >&2; exit 2 ;; esac; done
if [ -n "$MODE" ]; then "$HERE/city.sh" "$P" "$MODE"; "$HERE/processing.sh" "$P" "$MODE"; exit; fi
if [ "$DB" = 1 ]; then
    [ "$P" = default ] && { echo "--db is refused for the default profile (tmc_dev is shared)" >&2; exit 2; }
    ( load_profile "$P"; cd "$CITY_DIR" || exit 1
      echo "db: $DB_NAME"
      npx prisma db push && npm run db:idx:sync && npm run db:mv:sync && npm run db:ch:sync || exit 1
      if [ "$P" = games ]; then npm run db:seed:dev-games || exit 1; fi ) || { echo "db upkeep failed" >&2; exit 1; }
fi
"$HERE/city.sh" "$P"; c=$?
"$HERE/processing.sh" "$P"; p=$?
exit $(( c || p ))
