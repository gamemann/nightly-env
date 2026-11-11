#!/usr/bin/env bash
# prune-wt-links.sh [-n]  (nightly 1737)
# Removes dangling symlinks in /home/gamedev/wt whose target is a deleted per-user worktree
# (/home/<user>/wt/<name>). hv enters another user's worktree through such a link (nightly 1723);
# when the worktree is removed, the link is left behind. Only symlinks are removed (rm without -r,
# never through a link); real directories and links to anything else are left alone.
# -n: dry run, list what would be removed.
# Run as gamedev: sudo -u gamedev /home/core/projects/nightly-env/godot/prune-wt-links.sh [-n]
# WT_LINKS_DIR overrides the directory (for tests).
set -u
WT=${WT_LINKS_DIR:-/home/gamedev/wt}
dry=0
case "${1:-}" in
  -n) dry=1 ;;
  '') ;;
  *) echo "usage: $0 [-n]" >&2; exit 2 ;;
esac
[ -d "$WT" ] || { echo "prune-wt-links: no directory $WT" >&2; exit 2; }

removed=0; kept=0
while IFS= read -r -d '' l; do
  t=$(readlink -- "$l") || continue
  # Only links to a direct child of some user's ~/wt: /home/<user>/wt/<name>
  [[ $t =~ ^/home/[^/]+/wt/[^/]+$ ]] || { kept=$((kept+1)); continue; }
  parent=${t%/*}
  # The worktree's parent must be searchable by us, so ENOENT on the target is authoritative.
  [ -x "$parent" ] || { echo "skip $l -> $t (cannot search $parent)" >&2; kept=$((kept+1)); continue; }
  [ -e "$l" ] && { kept=$((kept+1)); continue; }   # resolves: not dangling
  if [ "$dry" = 1 ]; then
    echo "would remove $l -> $t"
  else
    rm -- "$l" && echo "removed $l -> $t"
  fi
  removed=$((removed+1))
done < <(find "$WT" -mindepth 1 -maxdepth 1 -type l -print0)

echo "prune-wt-links: $removed dangling link(s) $([ "$dry" = 1 ] && echo 'listed' || echo 'removed'), $kept kept"
