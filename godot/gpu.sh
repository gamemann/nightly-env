#!/usr/bin/env bash
# Launcher for the family's gpu.sh. The real script is dot-bootstrap/tools/gpu.sh in the gamedev
# godot tree, which is not beside this checkout, so it is found through GODOT_BOOTSTRAP (the
# dot-bootstrap directory) or the default below. It is exec'd by its absolute path, so the real
# script derives its own ROOT (the godot tree) from where it lives. GODOT_ROOT and WT_ROOT are
# read there and pass through this wrapper unchanged.
boot="${GODOT_BOOTSTRAP:-/home/gamedev/projects/godot/dot-bootstrap}"
real="$boot/tools/gpu.sh"
[[ -f "$real" ]] || { echo "gpu.sh: no tools/gpu.sh under $boot (set GODOT_BOOTSTRAP to the dot-bootstrap directory)" >&2; exit 2; }
exec "$real" "$@"
