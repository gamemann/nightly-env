#!/usr/bin/env bash
# fleet-watchdog (cron, every 3 min, as gamedev): keeps dev02's heavy lane moving without anyone watching it.
#  1. kills hung headless Godot jobs: idle (<2% CPU) for >20 min, older than 48 min (heavy's own cap is 45), pegged >=90% CPU for >25 min under
#     --quit-after (a finished scene would have quit), or orphaned (parent init) for >10 min
#  2. finds jobs waiting in dev02's queue that the offload hook can NOT send to staging/staging02 (bash -c wrappers,
#     GODOT=, absolute --path, GPU_OFFLOAD=0) while a box has free suite slots: lists them in ineligible.txt
#  3. writes health.txt (one line per fact) and an actions log: ~/.fleet/{health.txt,ineligible.txt,actions.log}
set -u
D=$HOME/.fleet; mkdir -p "$D"; export PATH=/home/gamedev/.local/bin:$PATH
ts() { date '+%F %T'; }
act() { printf '%s %s\n' "$(ts)" "$*" >> "$D/actions.log"; }
touch "$D/actions.log"; [ "$(wc -c < "$D/actions.log")" -gt 500000 ] && tail -n 2000 "$D/actions.log" > "$D/actions.log.new" && mv "$D/actions.log.new" "$D/actions.log"

# 1. stuck jobs
killed=0
while read -r pid ppid et pcpu cmd; do
  case "$cmd" in /home/gamedev/.local/bin/godot*|godot*) ;; *) continue ;; esac   # the godot binary itself: never ssh/bash wrappers (an offloaded job is an idle ssh by design)
  case "$cmd" in *--headless*|*--script*) ;; *) continue ;; esac
  why=
  [ "$et" -gt 2900 ] && why="running ${et}s (>48 min)"
  [ -z "$why" ] && [ "$ppid" = 1 ] && [ "$et" -gt 600 ] && why="orphan (parent init) ${et}s"
  [ -z "$why" ] && [ "$et" -gt 1500 ] && [ "${pcpu%.*}" -ge 90 ] && case "$cmd" in *--quit-after*) why="pegged ${pcpu}% for ${et}s under --quit-after" ;; esac
  [ -z "$why" ] && [ "$et" -gt 1200 ] && [ "${pcpu%.*}" -lt 2 ] && why="idle (${pcpu}% CPU over ${et}s): waiting on something that will never come"
  [ -n "$why" ] && { kill "$pid" 2>/dev/null && { act "KILLED pid $pid: $why: ${cmd:0:160}"; killed=$((killed+1)); }; }
done < <(ps -u gamedev -o pid=,ppid=,etimes=,pcpu=,cmd= 2>/dev/null)


# 1b. the same rule on the staging boxes (a hung offloaded godot holds a box suite slot; queue-watch.sh only clears orphaned Xvfb/gate waiters)
for spec in "staging:gamedev@staging.deacon.internal" "staging02:gamedev@staging02.deacon.internal"; do
  box=${spec%%:*}; dest=${spec#*:}
  out=$(timeout 40 ssh -i "$HOME/.ssh/gpu-laptop" -o ConnectTimeout=8 -o BatchMode=yes "$dest" '
    ps -eo pid=,etimes=,pcpu=,comm=,args= | while read -r pid et pcpu comm args; do
      [ "$comm" = godot ] || continue
      case "$args" in *--headless*) ;; *) continue ;; esac
      why=
      [ "$et" -gt 2900 ] && why="running ${et}s"
      [ -z "$why" ] && [ "$et" -gt 1500 ] && [ "${pcpu%.*}" -lt 2 ] && why="idle ${pcpu}% over ${et}s"
      [ -n "$why" ] && { kill "$pid" 2>/dev/null && echo "KILLED remote pid $pid ($why): ${args:0:120}"; }
    done' 2>&1) || out=""
  [ -n "$out" ] && while read -r line; do act "$box: $line"; killed=$((killed+1)); done <<<"$out"
done
# 2. status + ineligible waiters
st=$(timeout 60 heavy --status 2>&1)
printf '%s\n' "$st" > "$D/heavy.status"
busy=$(grep -c '^busy  build' <<<"$st")
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
  echo "local_build_slots_busy=$busy/5"
  echo "heavy_wrappers=$waiters (running+waiting)"
  echo "remote_suite_slots_free=$free_remote"
  echo "ineligible_for_offload=$bad (see ineligible.txt)"
  echo "killed_this_run=$killed"
  [ "$busy" -ge 5 ] && [ "$free_remote" -gt 0 ] && [ "$bad" -gt 0 ] && echo "ALERT=local lane full while boxes idle: $bad jobs use a non-offerable form (use /home/gamedev/bin/hv)"
  [ "$busy" -ge 5 ] && [ "$free_remote" -gt 4 ] && [ "$bad" = 0 ] && echo "ALERT=local lane full, boxes idle, jobs look eligible: check gpu.sh offer (heavy offers every 15 s)"
} > "$D/health.txt"
