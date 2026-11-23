#!/usr/bin/env bash
# Rebuild the dev checkouts on a fresh box. Run as the target user (core or gamedev) after that user has a GitHub SSH key.
#   ./restore.sh core|gamedev [--dry-run]
# Clones every repo in manifest-repos.tsv for that user to its original path (skips existing), then run install.sh. Machine-level Nightly parts (daemon, nginx, scc) come from install-nightly.sh, run separately.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
who="${1:?usage: restore.sh core|gamedev [--dry-run]}"; dry="${2:-}"
while IFS=$'\t' read -r u path remote branch; do
  [ "$u" = "$who" ] || continue
  if [ "$branch" = "link" ]; then  # a renamed checkout's old name, kept as a symlink: path -> remote column
    if [ -e "$path" ] || [ -L "$path" ]; then echo "have $path"; continue; fi
    echo "link $path -> $remote"
    [ "$dry" = "--dry-run" ] || ln -s "$remote" "$path"
    continue
  fi
  if [ -e "$path/.git" ]; then echo "have $path"; continue; fi
  echo "clone $remote -> $path"
  [ "$dry" = "--dry-run" ] && continue
  mkdir -p "$(dirname "$path")"; git clone "$remote" "$path" || echo "FAILED $remote" >&2
done < "$HERE/manifest-repos.tsv"
[ "$dry" = "--dry-run" ] || "$HERE/install.sh" "$who"
echo "Next: restore private files (see docs/RECOVERY.md), crontab, systemd --user enable, dev DB seeds."
[ "$who" = core ] && echo "Then, as root-capable user: ./install-nightly.sh --planet (panel box) or --station (offload box) for the nightly-node daemon, nginx site and scc."
