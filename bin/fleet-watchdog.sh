#!/usr/bin/env bash
# fleet-watchdog (cron, every 3 min, as gamedev): keeps dev02's heavy lane moving without anyone watching it.
#  1. kills hung headless Godot jobs: idle (<2% CPU) for >20 min, older than 48 min (heavy's own cap is 45), pegged >=90% CPU for >25 min under
#     --quit-after (a finished scene would have quit), or orphaned (parent init) for >10 min; and (2026-11-08) after a script parse
#     error: idle (<2% CPU measured since the last run, >=150 s) and its stdout log, a file quiet for >=3 min, says
#     "Failed to load script" / "SCRIPT ERROR: Parse Error" (Godot then waits forever; hv scene imports first to avoid it).
#     The same >48 min / >25 min idle rules run on staging, staging02 and PH (PH's janitor only kills after 3 h).
#     (2026-11-08) The age limit is max(48 min, the job's own `timeout N` + 2 min): a godot whose parent is
#     `timeout N` (game.sh's per-suite limit, e.g. headless_imported=3000, or hv shard's T) is allowed to run that long,
#     so legitimate long suites are not killed at 48 min. The idle and parse-error rules still apply to them.
#  2. finds jobs waiting in dev02's queue that the offload hook can NOT send to staging/staging02 (bash -c wrappers,
#     GODOT=, absolute --path, GPU_OFFLOAD=0) while a box has free suite slots: lists them in ineligible.txt
#  3. writes health.txt (one line per fact) and an actions log: ~/.fleet/{health.txt,ineligible.txt,actions.log}
set -u
D=$HOME/.fleet; mkdir -p "$D"; export PATH=/home/gamedev/.local/bin:/usr/local/bin:$PATH
ts() { date '+%F %T'; }
act() { printf '%s %s\n' "$(ts)" "$*" >> "$D/actions.log"; }
touch "$D/actions.log"; [ "$(wc -c < "$D/actions.log")" -gt 500000 ] && tail -n 2000 "$D/actions.log" > "$D/actions.log.new" && mv "$D/actions.log.new" "$D/actions.log"

# 1. stuck jobs
killed=0
# ps pcpu is the average over the whole life of the process; the parse-error rule needs the CPU used since the last run,
# so each run keeps "pid starttime cpu-ticks epoch" per godot (from /proc/<pid>/stat) and compares with the previous one.
declare -A prev
[ -f "$D/godot-cpu.prev" ] && while read -r p a b c; do prev[$p]="$a $b $c"; done < "$D/godot-cpu.prev"
now=$(date +%s); hz=$(getconf CLK_TCK 2>/dev/null || echo 100); : > "$D/godot-cpu.next"
while read -r pid ppid et pcpu cmd; do
  case "$cmd" in /home/gamedev/.local/bin/godot*|godot*) ;; *) continue ;; esac   # the godot binary itself: never ssh/bash wrappers (an offloaded job is an idle ssh by design)
  case "$cmd" in *--headless*|*--script*) ;; *) continue ;; esac
  why=
  st=; tk=
  if s=$(cat "/proc/$pid/stat" 2>/dev/null); then
    read -ra f <<< "${s##*) }"   # fields from 3 on: utime=14, stime=15, starttime=22
    tk=$(( ${f[11]:-0} + ${f[12]:-0} )); st=${f[19]:-}
    echo "$pid $st $tk $now" >> "$D/godot-cpu.next"
  fi
  lim=2900; pa=$(ps -o args= -p "$ppid" 2>/dev/null)
  [[ $pa =~ ^timeout\ ((-[ks]\ [^\ ]+|-[^\ ]+)\ )*([0-9]+)s?\  ]] && [ $(( ${BASH_REMATCH[3]} + 120 )) -gt $lim ] && lim=$(( ${BASH_REMATCH[3]} + 120 ))
  [ "$et" -gt "$lim" ] && why="running ${et}s (>$((lim / 60)) min)"
  [ -z "$why" ] && [ "$ppid" = 1 ] && [ "$et" -gt 600 ] && why="orphan (parent init) ${et}s"
  [ -z "$why" ] && [ "$et" -gt 1500 ] && [ "${pcpu%.*}" -ge 90 ] && case "$cmd" in *--quit-after*) why="pegged ${pcpu}% for ${et}s under --quit-after" ;; esac
  if [ -z "$why" ] && [ "$et" -gt 180 ] && [ -n "$st" ] && [ -n "${prev[$pid]:-}" ]; then
    read -r pst ptk pnow <<< "${prev[$pid]}"
    dt=$((now - pnow))
    if [ "$pst" = "$st" ] && [ "$dt" -ge 150 ] && [ $(( (tk - ptk) * 100 / (hz * dt) )) -lt 2 ]; then
      lf=$(readlink "/proc/$pid/fd/1" 2>/dev/null)
      if [ -f "$lf" ] && [ "$(stat -c %s "$lf" 2>/dev/null || echo 0)" -lt 209715200 ] &&
         [ $(( now - $(stat -c %Y "$lf" 2>/dev/null || echo "$now") )) -ge 180 ] &&
         grep -qE 'Failed to load script|SCRIPT ERROR: Parse Error' "$lf" 2>/dev/null; then
        why="parse error in $lf, idle (<2% CPU over the last ${dt}s, log quiet), ${et}s old"
      fi
    fi
  fi
  [ -z "$why" ] && [ "$et" -gt 1200 ] && [ "${pcpu%.*}" -lt 2 ] && why="idle (${pcpu}% CPU over ${et}s): waiting on something that will never come"
  [ -n "$why" ] && { kill "$pid" 2>/dev/null && { act "KILLED pid $pid: $why: ${cmd:0:160}"; killed=$((killed+1)); }; }
done < <(ps -u gamedev -o pid=,ppid=,etimes=,pcpu=,cmd= 2>/dev/null)
mv -f "$D/godot-cpu.next" "$D/godot-cpu.prev"


# 1b. the same rule on the staging boxes and PH (a hung offloaded godot holds a box suite slot; queue-watch.sh only clears orphaned
# Xvfb/gate waiters, PH's janitor only kills after 3 h; hosts from $FLEET_BOXES)
# FLEET_BOXES="name:user@host ..." comes from the private env file (never in git): see README
[ -r "${NIGHTLY_ENV_FILE:-$HOME/.config/nightly-env/env}" ] && . "${NIGHTLY_ENV_FILE:-$HOME/.config/nightly-env/env}"
for spec in ${FLEET_BOXES:-}; do
  box=${spec%%:*}; dest=${spec#*:}
  out=$(timeout 40 ssh -i "$HOME/.ssh/gpu-laptop" -o ConnectTimeout=8 -o BatchMode=yes "$dest" '
    ps -eo pid=,ppid=,etimes=,pcpu=,comm=,args= | while read -r pid ppid et pcpu comm args; do
      [ "$comm" = godot ] || continue
      case "$args" in *--headless*) ;; *) continue ;; esac
      why=; lim=2900; pa=$(ps -o args= -p "$ppid" 2>/dev/null)
      [[ $pa =~ ^timeout\ ((-[ks]\ [^\ ]+|-[^\ ]+)\ )*([0-9]+)s?\  ]] && [ $(( ${BASH_REMATCH[3]} + 120 )) -gt $lim ] && lim=$(( ${BASH_REMATCH[3]} + 120 ))
      [ "$et" -gt "$lim" ] && why="running ${et}s (limit ${lim}s)"
      [ -z "$why" ] && [ "$et" -gt 1500 ] && [ "${pcpu%.*}" -lt 2 ] && why="idle ${pcpu}% over ${et}s"
      [ -n "$why" ] && { kill "$pid" 2>/dev/null && echo "KILLED remote pid $pid ($why): ${args:0:120}"; }
    done' 2>&1) || out=""
  [ -n "$out" ] && while read -r line; do act "$box: $line"; killed=$((killed+1)); done <<<"$out"
done
# 2. status + ineligible waiters
st=$(timeout 60 heavy --status 2>&1)
printf '%s\n' "$st" > "$D/heavy.status"
busy=$(grep -c '^busy  build' <<<"$st")
# dev02's build slots (heavy.conf; was a hard-coded 5)
nslots=$(bash -c '. /etc/heavy.conf >/dev/null 2>&1; echo "${HEAVY_SLOTS_BUILD:-}"'); [[ $nslots =~ ^[0-9]+$ ]] || nslots=5
free_remote=$(grep -oE '[0-9]+/[0-9]+ suite slots free' <<<"$st" | awk -F'[/ ]' '{s+=$1} END{print s+0}')
: > "$D/ineligible.txt"; waiters=0; bad=0
while read -r pid cmd; do
  waiters=$((waiters+1))
  rest=${cmd#*heavy -- }
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
  ok=1; case "$rest" in *godot*|*game.sh*) ;; *) continue ;; esac
  case "$rest" in
    bash\ *|sh\ *|env\ GPU_*|GPU_*|*GPU_OFFLOAD*|*GODOT=*|*--godot\ *) ok=0 ;;
    *--path\ /*) ok=0 ;;
  esac
  case "$cwd" in /home/gamedev/wt/*/*) ok=0 ;; esac
  if [ $ok = 0 ]; then bad=$((bad+1)); printf '%s cwd=%s %s\n' "$pid" "$cwd" "${rest:0:200}" >> "$D/ineligible.txt"; fi
done < <(pgrep -u gamedev -f '^bash /usr/local/bin/heavy -- ' -a 2>/dev/null | sed 's/^\([0-9]*\) /\1 /')
{
  echo "time=$(ts)"
  echo "local_build_slots_busy=$busy/$nslots"
  echo "heavy_wrappers=$waiters (running+waiting)"
  echo "remote_suite_slots_free=$free_remote"
  echo "ineligible_for_offload=$bad (see ineligible.txt)"
  echo "killed_this_run=$killed"
  [ "$busy" -ge "$nslots" ] && [ "$free_remote" -gt 0 ] && [ "$bad" -gt 0 ] && echo "ALERT=local lane full while boxes idle: $bad jobs use a non-offerable form (use /home/gamedev/bin/hv)"
  [ "$busy" -ge "$nslots" ] && [ "$free_remote" -gt 4 ] && [ "$bad" = 0 ] && echo "ALERT=local lane full, boxes idle, jobs look eligible: check gpu.sh offer (heavy offers every 15 s)"
} > "$D/health.txt"

# 4. (2026-11-23) the published-artifact nightly: once a day, after 04:00, judge the CURRENTLY PUBLISHED prod shell pck and every
#    published game (tools/published_artifact_nightly.sh: static check + dedicated-server boot). It runs detached through hv's local
#    lane (a boot needs the built ./server tree here); a red night files/notes the nightly item published-artifact-drift itself.
#    Stamp: ~/.fleet/published-artifact.last (date of the last start); log: ~/.fleet/published-artifact.log (last run only).
PAN_REPO=/home/gamedev/godot/gs-server-deploy
if [ "$(date +%H)" -ge 4 ] && [ -x "$PAN_REPO/tools/published_artifact_nightly.sh" ] && [ -x "$PAN_REPO/server" ] &&
   [ "$(cat "$D/published-artifact.last" 2>/dev/null)" != "$(date +%F)" ] && ! pgrep -u gamedev -f 'published_artifact_nightly\.sh' >/dev/null; then
  date +%F > "$D/published-artifact.last"
  act "STARTED published_artifact_nightly (log $D/published-artifact.log)"
  ( cd "$PAN_REPO" && /home/gamedev/bin/hv "$PAN_REPO" local tools/published_artifact_nightly.sh > "$D/published-artifact.log" 2>&1
    rc=$?; printf '%s published_artifact_nightly exit %s\n' "$(ts)" "$rc" >> "$D/actions.log"
    echo "published_artifact_nightly_last=$(ts) exit=$rc" > "$D/published-artifact.status" ) >/dev/null 2>&1 &
fi
[ -f "$D/published-artifact.status" ] && cat "$D/published-artifact.status" >> "$D/health.txt"
