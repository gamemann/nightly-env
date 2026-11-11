#!/usr/bin/env bash
# Honest check that the GPU boxes really run heavy jobs side by side: submits four small headless
# runs through heavy at once (so the whole route -> hook -> box path is used), samples
# `gpu.sh capacity` while they run, and prints which box took each and the most jobs seen at once.
# Passes when all four succeeded, at least three ran on a box and at least three were seen running at once.
# Four different projects, because a box runs one job per project (they share its workspace).
# Usage: tools/gpu-lanes-check.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
jobs=("dot-core examples/addon_config_selftest" "dot-team examples/team_selftest" "dot-locale examples/locale_selftest" "dot-vote examples/vote_selftest")
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
i=0
for j in "${jobs[@]}"; do
	i=$((i + 1)); set -- $j
	( cd "$ROOT/$1" && heavy -- timeout 300 godot --headless --path . "res://$2.tscn" >"$out/$i.log" 2>&1; echo $? >"$out/$i.rc" ) &
done
max=0
while [ "$(ls "$out"/*.rc 2>/dev/null | wc -l)" -lt 4 ]; do
	n=$("$ROOT/gpu.sh" capacity 2>/dev/null | grep -cE "running:.* (dot-core|dot-team|dot-locale|dot-vote): godot --headless")
	[ "$n" -gt "$max" ] && max=$n
	sleep 1
done
wait
ok=0 boxed=0
for i in 1 2 3 4; do
	rc=$(cat "$out/$i.rc"); where=local
	grep -q 'took this suite' "$out/$i.log" && { where=$(grep -o 'the [a-z]* ([a-z0-9]*)' "$out/$i.log" | head -1); boxed=$((boxed + 1)); }
	[ "$rc" = 0 ] && ! grep -q '[1-9][0-9]* failed' "$out/$i.log" && ok=$((ok + 1))
	echo "job $i (${jobs[$((i - 1))]%% *}): rc=$rc on $where: $(grep -h 'passed' "$out/$i.log" | tail -1)"
done
echo "most jobs seen running on the boxes at once: $max; on a box: $boxed/4; passed: $ok/4"
[ "$ok" = 4 ] && [ "$boxed" -ge 3 ] && [ "$max" -ge 3 ]
