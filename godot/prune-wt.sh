#!/usr/bin/env bash
# prune.sh [-n]  (nightly wt-prune-sh-missing-1737)
# Per-user worktree sweep, installed as ~/wt/prune.sh (one canonical copy in nightly-env/godot,
# symlinked from /home/christian/wt and /home/gamedev/wt).
#
# 1. Merged, clean worktrees under $HOME/wt are removed with `git worktree remove` (no --force).
#    A worktree is removed only when all of these hold; anything else is kept and reported:
#      - it is a linked worktree (its .git is a file), not a full clone
#      - no modified or untracked files (git status --porcelain is empty)
#      - HEAD is on a branch with an upstream, and no commit is missing from that upstream
#        (nothing unpushed)
#      - HEAD is an ancestor of origin/main (or origin/master), i.e. merged. Refs are not fetched;
#        a stale origin/main only keeps more worktrees, never removes more.
#      - no symlink under a checkout's or worktree's addons/ resolves into it (a game's addons/gs_game link)
#    Branches are not deleted.
# 2. Dangling links in /home/gamedev/wt are swept by godot/prune-wt-links.sh (nightly 1737),
#    run as gamedev because that directory belongs to gamedev.
#
# -n: dry run, print what would be removed and what is kept; changes nothing.
set -u

LINKS_SCRIPT=${PRUNE_LINKS_SCRIPT:-/home/core/projects/nightly-env/godot/prune-wt-links.sh}
WT=${PRUNE_WT_DIR:-$HOME/wt}
dry=0
case "${1:-}" in
  -n) dry=1 ;;
  '') ;;
  *) echo "usage: $0 [-n]" >&2; exit 2 ;;
esac

removed=0; kept=0

# Symlink targets (nightly prune-sh-removes-1): a game's addons/gs_game may link into a worktree of
# another repo, and removing that worktree leaves the game with a dangling addon. Collect every
# symlink target under the addons dirs of the checkouts and worktrees once; a worktree that is, or
# contains, one of those targets is kept.
LINK_ROOTS=${PRUNE_LINK_ROOTS:-"$HOME/wt /home/gamedev/wt /home/gamedev/godot"}
link_targets=$(
  for r in $LINK_ROOTS; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth 4 -type l -path '*/addons/*' -print0 2>/dev/null
  done | xargs -0 -r -n1 readlink -f 2>/dev/null | sort -u
)
is_link_target() {  # is_link_target <worktree dir>: 0 when some link resolves into it
  printf '%s\n' "$link_targets" | awk -v d="$(readlink -f "$1")" 'index($0, d "/") == 1 || $0 == d { f = 1 } END { exit !f }'
}

[ -d "$WT" ] || { echo "prune: no directory $WT" >&2; exit 2; }

for d in "$WT"/*/; do
  d=${d%/}
  [ -L "$d" ] && continue            # links (e.g. fc-surf-dm-maps) are not worktrees
  [ -f "$d/.git" ] || continue       # only linked worktrees have a .git file
  name=${d##*/}

  if is_link_target "$d"; then echo "keep $name: a symlink under some addons/ points into it"; kept=$((kept+1)); continue; fi

  common=$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
  base=""
  for b in origin/main origin/master; do
    git -C "$d" rev-parse --verify -q "$b" >/dev/null 2>&1 && { base=$b; break; }
  done
  if [ -z "$base" ]; then echo "keep $name: no origin/main or origin/master"; kept=$((kept+1)); continue; fi

  branch=$(git -C "$d" symbolic-ref -q --short HEAD 2>/dev/null) || { echo "keep $name: detached HEAD"; kept=$((kept+1)); continue; }
  up=$(git -C "$d" rev-parse -q --verify "@{u}" 2>/dev/null) || { echo "keep $name: $branch has no upstream"; kept=$((kept+1)); continue; }
  ahead=$(git -C "$d" rev-list --count "$up..HEAD" 2>/dev/null) || ahead=-1
  if [ "$ahead" != 0 ]; then echo "keep $name: $ahead unpushed commit(s) on $branch"; kept=$((kept+1)); continue; fi
  if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then echo "keep $name: uncommitted or untracked changes"; kept=$((kept+1)); continue; fi
  if ! git -C "$d" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then echo "keep $name: $branch not merged into $base"; kept=$((kept+1)); continue; fi

  if [ "$dry" = 1 ]; then
    echo "would remove $name ($branch, merged into $base, clean, pushed)"
  elif git --git-dir="$common" worktree remove -- "$d" 2>/dev/null; then
    echo "removed $name ($branch)"
  else
    echo "keep $name: git refused to remove it"; kept=$((kept+1)); continue
  fi
  removed=$((removed+1))
done

echo "prune: $removed worktree(s) $([ "$dry" = 1 ] && echo 'listed' || echo 'removed'), $kept kept"

# Dangling-link sweep for /home/gamedev/wt. gamedev owns that directory, so run it as gamedev.
if [ "$(id -un)" = gamedev ]; then runner=""; else runner="sudo -n -u gamedev"; fi
if [ -x "$LINKS_SCRIPT" ]; then
  if [ "$dry" = 1 ]; then
    $runner "$LINKS_SCRIPT" -n || echo "prune: link sweep failed" >&2
  else
    $runner "$LINKS_SCRIPT" || echo "prune: link sweep failed" >&2
  fi
else
  echo "prune: link sweep missing: $LINKS_SCRIPT" >&2
fi
exit 0
