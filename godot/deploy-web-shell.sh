#!/usr/bin/env bash
# The manual fallback for publishing the web shell. The uploader moved into
# dot-server-deploy as tools/publish-web-shell.sh (2026-10-20), where the web-shell
# workflow runs it on every push that changes the shell's inputs; this wrapper keeps the
# old command line working on this box and supplies the .env beside it.
#
#   ./deploy-web-shell.sh --repo /path/to/lock-exact-clone --zip <that clone>/web/build.zip --pin
#
# --pin needs the export to come from a checkout whose addons are EXACTLY at addons.lock.
# ./dot-server-deploy here links the sibling addon checkouts, usually ahead of their tags;
# export-web marks that build off-lock and the pin refuses it. Use a separate clone set
# up with `./setup.sh --no-games` (its own clones, at the lock), export there, pin there.
#
# --repo DIR (or SHELL_DEPLOY_REPO) picks the checkout, default ./dot-server-deploy; its
# own copy of the tool runs. --env FILE (or SHELL_ENV_FILE) overrides ./.env.
# --dev uses ./.env.dev (the dev bucket) instead of ./.env (prod); never combine it with --pin.
# --dev also registers the build on dev_games afterwards (tools/dev-shell-publish.sh --register-only).
# --api SITE --app FOLDER (or SHELL_API / SHELL_PUBLISH_TOKEN in the env file) publishes through the site's web build
# API instead of writing to the bucket; it passes straight through (needs dot-server-deploy at or after dfa9518).
# Everything else is publish-web-shell.sh's: run it with --help.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=${SHELL_DEPLOY_REPO:-$HERE/dot-server-deploy}
has_env=0
dev=0
build=
args=()
for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        --repo) j=$((i + 1)); REPO=${!j:-} ;;
        --env) has_env=1 ;;
    esac
done
# --dev publishes to the dev games bucket (served by dev.dotgames.org) with ./.env.dev.
for a in "$@"; do
    if [ "$a" = --dev ]; then dev=1; has_env=1; args+=(--env "$HERE/.env.dev"); else args+=("$a"); fi
done
set -- "${args[@]}"

TOOL="$REPO/tools/publish-web-shell.sh"
[ -x "$TOOL" ] || { echo "error: $TOOL is missing; is $REPO a current dot-server-deploy checkout?" >&2; exit 1; }

extra=(--repo "$REPO")
if [ "$has_env" = 0 ] && [ -z "${SHELL_ENV_FILE:-}" ] && [ -f "$HERE/.env" ]; then
    extra+=(--env "$HERE/.env")
fi
# --dev also registers the build on dev_games (dev-shell-publish.sh), so games.tmcdev.net frames it.
if [ "$dev" = 1 ]; then
    for ((i = 1; i <= $#; i++)); do if [ "${!i}" = --build ]; then j=$((i + 1)); build=${!j}; fi; done
    if [ -z "$build" ]; then build=$(date -u +%Y%m%d-%H%M); extra+=(--build "$build"); fi
    "$TOOL" "${extra[@]}" "$@"
    case " $* " in *" --dry-run "*) exit 0 ;; esac
    exec "$REPO/tools/dev-shell-publish.sh" --register-only --build "$build"
fi
exec "$TOOL" "${extra[@]}" "$@"
