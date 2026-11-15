#!/usr/bin/env bash
# hv: an INFRA KILL (gpu.sh, rc 143/137) is retried on another box (max 2, skipping the killed box), and the caller's
# GPU_SUITE_BOXES / GPU_OFFLOAD reach heavy. A stub `heavy` on PATH stands in for the real one; no box or Godot is used.
# Usage: tests/test_hv_infra_retry.sh
set -u
HV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/hv"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/proj"; : > "$T/proj/project.godot"; : > "$T/proj/game.sh"
cat > "$T/bin/heavy" <<'STUB'
#!/usr/bin/env bash
# kills (INFRA KILL, rc $KILL_RC) the first $KILLS calls, naming the first box of GPU_SUITE_BOXES; then passes.
n=$(cat "$STATE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STATE"
echo "call $n boxes=[${GPU_SUITE_BOXES-unset}] offload=[${GPU_OFFLOAD-unset}]" >> "$STATE.log"
if [ "$n" -le "${KILLS:-0}" ]; then
  bx=${GPU_SUITE_BOXES:-ph staging02 staging}; b=${bx%% *}; echo "gpu.sh: INFRA KILL on $b: the job was killed (rc $KILL_RC), not a suite failure" >&2; exit "$KILL_RC"
fi
echo "suite ok"; exit 0
STUB
chmod +x "$T/bin/heavy"
pass=0; fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
run() { # name expected-rc expected-calls expected-log-substring [env...]
  local name=$1 erc=$2 ecalls=$3 sub=$4; shift 4
  rm -f "$T/state" "$T/state.log"
  env -u GPU_SUITE_BOXES -u GPU_OFFLOAD -u GPU_BOX STATE="$T/state" PATH="$T/bin:$PATH" HV_NO_PREFLIGHT=1 HV_NO_GUARD=1 "$@" "$HV" "$T/proj" game test x >"$T/out" 2>&1
  local rc=$? calls; calls=$(cat "$T/state" 2>/dev/null || echo 0)
  [ "$rc" = "$erc" ] && [ "$calls" = "$ecalls" ] && grep -qF -- "$sub" "$T/state.log" && ok "$name" || { bad "$name: rc=$rc calls=$calls"; cat "$T/state.log" "$T/out" 2>/dev/null | sed 's/^/       /'; }
}
run "143 INFRA KILL retried on another box" 0 2 "call 2 boxes=[staging02 staging]" KILLS=1 KILL_RC=143
run "137 INFRA KILL retried" 0 2 "call 2 boxes=[staging02 staging]" KILLS=1 KILL_RC=137
run "two kills: third call skips both killed boxes" 0 3 "call 3 boxes=[staging]" KILLS=2 KILL_RC=143
run "max 2 retries: third kill stands" 143 3 "call 3 boxes=[staging]" KILLS=9 KILL_RC=143
run "caller GPU_SUITE_BOXES honoured and shrunk" 0 2 "call 2 boxes=[b c]" KILLS=1 KILL_RC=143 GPU_SUITE_BOXES="a b c"
run "no other box left: rc stands" 143 1 "call 1 boxes=[a]" KILLS=9 KILL_RC=143 GPU_SUITE_BOXES=a
run "GPU_OFFLOAD=0 passed through" 0 1 "offload=[0]" GPU_OFFLOAD=0
run "GPU_SUITE_BOXES passed through unchanged" 0 1 "boxes=[ph x]" GPU_SUITE_BOXES="ph x"
run "GPU_BOX pinned: no retry" 143 1 "call 1" KILLS=9 KILL_RC=143 GPU_BOX=ph GPU_SUITE_BOXES="ph x"
# a plain 143 (no INFRA KILL line) is not an infra kill
rm -f "$T/state"; cat > "$T/bin/heavy" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$STATE" 2>/dev/null || echo 0); echo $((n + 1)) > "$STATE"; exit 143
STUB
STATE="$T/state" PATH="$T/bin:$PATH" HV_NO_PREFLIGHT=1 HV_NO_GUARD=1 "$HV" "$T/proj" game test x >/dev/null 2>&1; rc=$?
[ "$rc" = 143 ] && [ "$(cat "$T/state")" = 1 ] && ok "143 without an INFRA KILL line is not retried" || bad "plain 143: rc=$rc calls=$(cat "$T/state")"
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
