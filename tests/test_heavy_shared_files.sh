#!/usr/bin/env bash
# heavy: lock/.who/peaks files left by ANOTHER user (mode 644) must not stop this user's run (was exit 70 on PH, 2026-11-15),
# and files heavy creates itself must be world-writable. Needs `sudo -n -u <other>`; skips (exit 0) without it.
# Usage: tests/test_heavy_shared_files.sh
set -u
HEAVY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/heavy"
other=
for u in core gamedev nobody; do
  [ "$u" = "$(id -un)" ] && continue
  id "$u" >/dev/null 2>&1 && sudo -n -u "$u" true 2>/dev/null && { other=$u; break; }
done
[ -n "$other" ] || { echo "SKIP: no other user reachable with sudo -n"; exit 0; }
T=$(mktemp -d /tmp/heavy-shared.XXXXXX); chmod 1777 "$T"
trap 'sudo -n -u "$other" rm -rf "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok() { if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }
run() { HEAVY_DIR=$T HEAVY_MIN_AVAIL_GB=0 HEAVY_JOB_MAX_GB=0 HEAVY_ALLOW_UNCAPPED=1 HEAVY_OFFLOAD= timeout 60 "$HEAVY" --lane check -- "$@" 2>&1; }

# 1. foreign 644 files (the PH case)
sudo -n -u "$other" sh -c "umask 022; : > $T/check.1.lock; : > $T/check.1.who; echo x > $T/peaks"
out=$(run true); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ]; ok "foreign 644 lock/who/peaks: run succeeds, no stderr noise (rc=$rc)" $?
[ -z "$out" ] || echo "  output: $out" | head -3

# 2. a lock the other user holds is still honoured (we queue, --max-wait gives up with 124), not exit 70
sudo -n -u "$other" bash -c "exec 9>>$T/check.1.lock; flock -n 9 && sleep 8" & sleep 1
HEAVY_DIR=$T HEAVY_MIN_AVAIL_GB=0 HEAVY_SLOTS_CHECK=1 HEAVY_JOB_MAX_GB=0 HEAVY_ALLOW_UNCAPPED=1 HEAVY_OFFLOAD= timeout 60 "$HEAVY" --max-wait 2 --lane check -- true >/dev/null 2>&1; rc=$?
[ "$rc" = 124 ]; ok "foreign-held lock on a 644 file: waits and gives up (124), not 70 (rc=$rc)" $?
wait

# 3. files created by heavy itself are world-writable
rm -rf "$T"/*; sudo -n -u "$other" true
run true >/dev/null; rc=$?
bad=$(find "$T" -maxdepth 1 \( -name '*.lock' -o -name '*.who' -o -name peaks \) ! -perm -666 | wc -l)
n=$(find "$T" -maxdepth 1 -name '*.lock' | wc -l)
[ "$rc" = 0 ] && [ "$n" -ge 1 ] && [ "$bad" = 0 ]; ok "created lock/who are mode 666 (locks=$n, not-666=$bad)" $?

# 4. peaks written by us can be appended and trimmed by the other user (no mv-over-foreign-file failure)
printf 'k\t5\n' > "$T/peaks"; chmod 666 "$T/peaks"
sudo -n -u "$other" sh -c "printf 'k\t6\n' >> $T/peaks"; ok "peaks appendable by another user" $?
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
