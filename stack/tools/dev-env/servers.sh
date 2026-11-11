#!/bin/bash
# The dev game servers on this VM's Wings node (one Pterodactyl server per game plus "multi") for one dev profile. See ~/docs/dev-environment.md.
#   tools/dev-env/servers.sh PROFILE ACTION [-n N] [REPO... | all]
#   PROFILE   default (tmcdev.net, tmc_dev), games (games.tmcdev.net, dev_games), claude (claude.tmcdev.net, tmc_claude)
#   up        provision for the profile, restart, wait until each holds a token from the profile's site (3 min each)
#   prove     create any that do not exist (waits for the install), provision, start, wait for the token, then stop
#             the ones outside the default set; -n N runs N at a time (default 1: gameservers.slice holds 8 GB, ~400 MB each)
#   provision point the servers at the profile's site (drops the old site's credential when the site changes)
#   start | stop | restart   -n N starts at most N (refuses more, so the node is not overcommitted by accident)
#   list | check [--browser]
# REPO defaults to the default running set, game-arena game-zombie-zone; "all" is every server in devenv.py GAMES.
# The profile's site must be up (dev01: ~/stack/dev-env/city.sh PROFILE) with claimed rows (npm run db:seed:dev-games).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVENV=(python3 "$HERE/devenv.py")
DEFAULT_SET=(game-arena game-zombie-zone)
PROFILE=${1:?profile: default, games or claude}; ACTION=${2:?action: up, prove, provision, start, stop, restart, list, check}; shift 2
case "$PROFILE" in default) SITE=https://tmcdev.net ;; games) SITE=https://games.tmcdev.net ;; claude) SITE=https://claude.tmcdev.net ;;
    *) echo "unknown profile: $PROFILE" >&2; exit 2 ;; esac
if [ "$ACTION" = check ]; then exec "$HERE/../dev-env-check.sh" --profile "$PROFILE" "$@"; fi
N=0; REPOS=()
while [ $# -gt 0 ]; do
    case "$1" in -n) N=$2; shift 2 ;; all) mapfile -t -O "${#REPOS[@]}" REPOS < <(cd "$HERE" && python3 -c 'import devenv; print("\n".join(g for g, _ in devenv.GAMES))'); shift ;;
        *) REPOS+=("$1"); shift ;; esac
done
[ ${#REPOS[@]} -gt 0 ] || REPOS=("${DEFAULT_SET[@]}")

has_token() {  # only whether a token is there is printed, never the token
    sudo cat "/var/lib/pterodactyl/volumes/$("${DEVENV[@]}" uuid "$1")/data/listing.json" 2>/dev/null |
        python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if str(d.get('integration_token','')).strip() and d.get('backbone_url','').rstrip('/')=='$SITE' else 1)" 2>/dev/null
}
installed() {  # 0 when the server exists and its install has finished
    (cd "$HERE" && python3 -c "
import sys, devenv
a = devenv.ours().get('$1')
sys.exit(0 if a and a['status'] is None and not devenv.call('client', 'GET', '/servers/' + a['identifier'])['attributes'].get('is_installing') else 1)")
}
wait_token() {
    for _ in $(seq 36); do has_token "$1" && break; sleep 5; done
    if has_token "$1"; then echo "$1: enrolled with $SITE"; else echo "$1: no token from $SITE after 3 min ($HERE/devenv.py console $1 80)"; return 1; fi
}
site_up() { curl -sf -m 60 -o /dev/null "$SITE/api/content/server/list?limit=1" || { echo "$SITE does not answer; start it first" >&2; exit 1; }; }
in_default() { local d; for d in "${DEFAULT_SET[@]}"; do [ "$d" = "$1" ] && return 0; done; return 1; }

case "$ACTION" in
    list) "${DEVENV[@]}" list ;;
    provision) "${DEVENV[@]}" provision --profile "$PROFILE" "${REPOS[@]}" ;;
    start|restart)
        if [ "$N" -gt 0 ] && [ ${#REPOS[@]} -gt "$N" ]; then echo "${#REPOS[@]} servers asked for, -n $N allows $N" >&2; exit 2; fi
        "${DEVENV[@]}" power "$ACTION" "${REPOS[@]}" ;;
    stop) "${DEVENV[@]}" power stop "${REPOS[@]}" ;;
    up)
        site_up
        "${DEVENV[@]}" provision --profile "$PROFILE" "${REPOS[@]}" && "${DEVENV[@]}" power restart "${REPOS[@]}" || exit 1
        fails=0
        for r in "${REPOS[@]}"; do wait_token "$r" || fails=$((fails + 1)); done
        exit "$fails" ;;
    prove)
        site_up
        [ "$N" -gt 0 ] || N=1
        fails=0
        for ((i = 0; i < ${#REPOS[@]}; i += N)); do
            batch=("${REPOS[@]:i:N}")
            for r in "${batch[@]}"; do
                "${DEVENV[@]}" create "$r"
                for _ in $(seq 180); do installed "$r" && break; sleep 10; done  # a first install fetches ~1 GB: 30 min cap
                installed "$r" || { echo "$r: still installing after 30 min" >&2; fails=$((fails + 1)); }
            done
            "${DEVENV[@]}" provision --profile "$PROFILE" "${batch[@]}" && "${DEVENV[@]}" power restart "${batch[@]}"
            for r in "${batch[@]}"; do wait_token "$r" || fails=$((fails + 1)); done
            for r in "${batch[@]}"; do in_default "$r" || "${DEVENV[@]}" power stop "$r"; done
        done
        exit "$fails" ;;
    *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac
