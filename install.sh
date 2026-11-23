#!/usr/bin/env bash
# Link the dev environment scripts from this repo into their live locations.
# Usage: ./install.sh gamedev   (run as the gamedev user, or: sudo -u gamedev ./install.sh gamedev)
#        ./install.sh core
# Existing regular files are moved to <path>.pre-nightly-env before linking. Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
who="${1:-}"
link() { # repo-relative src, absolute dest
  local src="$HERE/$1" dst="$2"
  [ -e "$src" ] || { echo "missing $src" >&2; return 1; }
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then return 0; fi
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then mv "$dst" "$dst.pre-nightly-env"; fi
  ln -sfn "$src" "$dst"; echo "linked $dst -> $src"
}
case "$who" in
  gamedev)
    link bin/hv /home/gamedev/bin/hv
    link bin/fleet-watchdog.sh /home/gamedev/bin/fleet-watchdog.sh
    for f in gpu.sh attach-shot.sh capture-reviews.sh deploy-web-shell.sh push-github.sh NOTES.md; do link godot/$f /home/gamedev/godot/$f; done
    link docs/gamedev-CLAUDE.md /home/gamedev/CLAUDE.md
    echo "crontab: sudo -u gamedev crontab $HERE/cron/gamedev.crontab (review first)" ;;
  core)
    link bin/phbuild /home/core/bin/phbuild
    link bin/ph-smoke /home/core/bin/ph-smoke
    link stack/dev.sh /home/core/projects/dev.sh
    link stack/kill-intensive.sh /home/core/projects/kill-intensive.sh
    for f in profile city games-stack processing; do link stack/dev-env/$f.sh /home/core/projects/dev-env/$f.sh; done
    for f in check-layout-sync.mjs check-layout-sync.sh claude-usage.sh; do link stack/scripts/$f /home/core/projects/scripts/$f; done
    mkdir -p /home/core/.config/systemd/user
    for f in stack-dev; do link systemd/$f.service /home/core/.config/systemd/user/$f.service; done
    link docs/stack-CLAUDE.md /home/core/projects/CLAUDE.md ;;
  *) echo "usage: $0 gamedev|core" >&2; exit 2 ;;
esac
echo "root-only: /usr/local/bin/heavy is a root-owned copy; update with: sudo install -m755 $HERE/bin/heavy /usr/local/bin/heavy"
