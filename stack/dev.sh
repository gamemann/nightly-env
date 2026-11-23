#!/usr/bin/env bash
#
# dev.sh -- bring the whole stack up in development with one command.
#
#   ./dev.sh                    # the default set: worker, city, processing, spy, bot
#   ./dev.sh city processing    # only these
#   ./dev.sh all                # everything, incl. website-learn, tmc-app and nightly
#   ./dev.sh --list             # what every name means
#   ./dev.sh --build-only       # compile what needs compiling, start nothing
#   ./dev.sh --stop             # stop everything this script can start
#   ./dev.sh --stop city learn  # stop only these
#
# There are two kinds of component here and they are deliberately NOT started
# the same way:
#
#   * The web apps (website-city, website-processing, website-learn, tmc-app)
#     run their own dev server with hot reload -- that is the point of them.
#   * Everything compiled -- Spy's Go binary, the Discord bot's TypeScript --
#     is BUILT first and then run from the build output. No watcher, no hot
#     reload: these are background services the web apps talk to, and a
#     half-compiled restart in the middle of a scan is noise, not help. The
#     build only runs when a source file is newer than the artifact, so a
#     second run of this script starts them straight away.
#
# Each component runs in its own process group. That is not decoration: `npm
# run dev` is a wrapper around `next dev`, so killing the wrapper alone leaves
# the real server holding port 3002 and the next run of this script skips city
# because "the port is busy". Ctrl-C signals the whole group instead.
#
# Ports match what nginx on tmcdev.net expects: 3002 website-city, 3003
# website-processing. Nothing here terminates TLS -- nginx does that and
# reverses to plain HTTP, so the dev servers stay HTTP.
#
# website-learn is the exception: nginx serves tmcdev.net/learn from that
# project's `dist/` rather than from :3004. Only one Vite dev server can own
# /@..., /src/ and /node_modules/ at the root of a host, and website-processing
# already does -- see the long note in /etc/nginx/sites-available/tmc.conf. The
# :3004 server below is still the one to write docs against; reach it directly.

set -uo pipefail
set -m   # one process group per background job -- see above.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT/.dev-logs"

# ---------------------------------------------------------------------------
# The component table
# ---------------------------------------------------------------------------

# Start order. worker comes first because spy and bot connect to the TCP
# listener it opens on 4322; shared comes first because city/processing import
# what it emits.
ORDER=(shared worker city processing learn app spy bot nightly)

declare -A DIR=(
    [shared]=tmc-global/shared
    [worker]=website-city
    [city]=website-city
    [processing]=website-processing
    [learn]=website-learn
    [app]=tmc-app
    [spy]=spy
    [bot]=spy-discord-bot
    [nightly]=nightly
)

# A component with a port here is skipped when that port is already taken --
# two Next dev servers sharing one .next directory corrupt each other's build,
# and a second worker would double every cron job.
declare -A PORT=(
    [city]=3002
    [processing]=3003
    [learn]=3004
    [app]=5173
    [worker]=4322
    [nightly]=3010
)

declare -A DESC=(
    [shared]="@modcommunity/shared    vite build --watch  (only useful on a local install)"
    [worker]="website-city worker     cron jobs + the Spy/Discord TCP listener on :4322"
    [city]="website-city            next dev on :3002"
    [processing]="website-processing      astro dev on :3003"
    [learn]="website-learn           astro dev on :3004  (direct only -- nginx serves the BUILT docs at /learn)"
    [app]="tmc-app                 vite dev on :5173  (desktop shell's web half)"
    [spy]="Spy                     Go query daemon -- built, then run"
    [bot]="spy-discord-bot         TypeScript -- built, then run from dist/"
    [nightly]="nightly                 next dev on :3010  (the Nightly panel; production: install-nightly.sh)"
)

declare -A COLOR=(
    [shared]=$'\033[35m'
    [worker]=$'\033[33m'
    [city]=$'\033[36m'
    [processing]=$'\033[32m'
    [learn]=$'\033[92m'
    [app]=$'\033[95m'
    [spy]=$'\033[34m'
    [bot]=$'\033[94m'
    [nightly]=$'\033[96m'
)
RESET=$'\033[0m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
RED=$'\033[31m'
YEL=$'\033[33m'

# Components with a port are guarded by the port check below. The ones without
# one still must not be started twice -- a second Spy double-scans every server
# the worker hands it -- so they are matched by "a process with this cmdline
# whose cwd is this component's directory", which is precise enough to ignore
# an unrelated dist/index.js elsewhere on the box.
declare -A GUARD_PAT=(
    [spy]='build/spy'
    [bot]='dist/index\.js'
    [shared]='vite build'
)

DEFAULT_SET=(worker city processing spy bot)

# Spy reads one JSON config. The repo-local one is the dev config (it points
# comm at 127.0.0.1:4322); /etc/tmc/spy.json is the deployed one.
SPY_CONFIG_LOCAL="$ROOT/spy/local.json"
SPY_CONFIG_SYSTEM="/etc/tmc/spy.json"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

SELECTED=()
DO_BUILD=1
FORCE_BUILD=0
BUILD_ONLY=0
STOP=0
DRY_RUN=0
STRICT=0
WORKER_WAIT=60

# The component rows, shared by --help and --list. A `*` marks the members of
# the default set, i.e. what runs when you name no component at all.
component_table() {
    local n mark
    for n in "${ORDER[@]}"; do
        mark=' '
        [[ " ${DEFAULT_SET[*]} " == *" $n "* ]] && mark='*'
        printf ' %s %b%-11s%b %s\n' "$mark" "${COLOR[$n]}" "$n" "$RESET" "${DESC[$n]}"
    done
    cat <<EOF

   all         every component above
   web         website-city + website-processing only
EOF
}

# --list: the component table on its own. --help already carries the options,
# so repeating them here would make the two flags the same command.
list_components() {
    printf '%bComponents%b  (%b*%b = the default set: %s)\n\n' \
        "$BOLD" "$RESET" "$BOLD" "$RESET" "${DEFAULT_SET[*]}"
    component_table
    printf '\n%bOptions: ./dev.sh --help%b\n' "$DIM" "$RESET"
}

usage() {
    cat <<EOF
${BOLD}dev.sh${RESET} -- run the whole stack in development.

Usage: ./dev.sh [options] [component ...]

Components (${BOLD}*${RESET} = default set):
EOF
    component_table
    cat <<EOF

Options:
  --rebuild       rebuild the compiled components even if they look current
  --skip-build    never build; run whatever artifact is already there
  --build-only    build the compiled components and exit
  --stop          stop the named components and exit -- with no names, every
                  component, not just the default set. Combine with --dry-run
                  to print what would be signalled and signal nothing.
  --dry-run       build, run every preflight check, print what would start,
                  and start nothing
  --strict        tear the whole stack down as soon as one component exits
                  (default: report it and keep the rest running)
  --wait N        seconds to wait for the worker's :4322 listener before
                  starting spy/bot anyway (default $WORKER_WAIT, 0 disables)
  --list, -l      print the component table and exit
  --help, -h      this text

Logs are mirrored, without colour, into .dev-logs/<component>.log
EOF
}

while (( $# )); do
    case $1 in
        --rebuild)    FORCE_BUILD=1 ;;
        --skip-build) DO_BUILD=0 ;;
        --build-only) BUILD_ONLY=1 ;;
        --stop)       STOP=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        --strict)     STRICT=1 ;;
        --wait)       WORKER_WAIT=${2:?--wait needs a number}; shift ;;
        -l|--list)    list_components; exit 0 ;;
        -h|--help)    usage; exit 0 ;;
        all)          SELECTED=("${ORDER[@]}") ;;
        web)          SELECTED+=(city processing) ;;
        -*)           echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [[ -v DIR[$1] ]]; then
                SELECTED+=("$1")
            else
                echo "unknown component: $1  (try --list)" >&2
                exit 2
            fi
            ;;
    esac
    shift
done

# Naming nothing means the default set when starting, but EVERY component when
# stopping. You reach for --stop to get the box back, and leaving learn or app
# up because they happen to sit outside the default start set is precisely the
# leftover this flag exists to clear.
if (( ${#SELECTED[@]} == 0 )); then
    if (( STOP )); then SELECTED=("${ORDER[@]}"); else SELECTED=("${DEFAULT_SET[@]}"); fi
fi

# Dedupe and put the selection back into start order.
WANTED=()
for n in "${ORDER[@]}"; do
    for s in "${SELECTED[@]}"; do
        if [[ $n == "$s" ]]; then WANTED+=("$n"); break; fi
    done
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

say()  { printf '%b==>%b %s\n' "$BOLD" "$RESET" "$*"; }
warn() { printf '%b !!%b %s\n' "$YEL" "$RESET" "$*"; }
bad()  { printf '%b !!%b %s\n' "$RED" "$RESET" "$*"; }
note() { printf '%b    %s%b\n' "$DIM" "$*" "$RESET"; }

port_busy() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }

port_owner() {
    ss -ltnpH "sport = :$1" 2>/dev/null |
        grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2
}

# pids whose cmdline matches $2 AND whose cwd is $1.
running_in_dir() {
    local dir=$1 pat=$2 pid cwd
    for pid in $(pgrep -f "$pat" 2>/dev/null); do
        [[ $pid == $$ ]] && continue
        cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null) || continue
        [[ $cwd == "$dir" ]] && echo "$pid"
    done
}

# Signals go to process GROUPS here, never to bare pids -- see the note at the
# top of this file: `npm run dev` is a wrapper, and killing the wrapper alone
# leaves the real server holding the port.
group_alive() { kill -0 -"$1" 2>/dev/null; }
pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }

# ---------------------------------------------------------------------------
# Stop
# ---------------------------------------------------------------------------

# Every pid that IS this component.
#
# A separate invocation has no PID table to consult -- that map lives and dies
# with the run that built it -- so --stop has to rediscover the processes from
# the outside. It does that the same two ways the preflight below already
# detects a duplicate: whoever owns the component's port, and whatever matches
# its guard pattern from inside its own directory. Between them those cover all
# eight, and they find a dev server this script never started just as well.
component_pids() {
    local name=$1 dir="$ROOT/${DIR[$name]}" pat=${GUARD_PAT[$name]:-} p=${PORT[$name]:-}
    {
        [[ -n $p ]]   && port_owner "$p"
        [[ -n $pat ]] && running_in_dir "$dir" "$pat"
    } | grep -xE '[0-9]+' | sort -un
}

stop_components() {
    local self_pgid name pid pgid seen g i p
    self_pgid=$(pgid_of $$)
    local -a names=() pgids=() absent=()

    for name in "${WANTED[@]}"; do
        local -a pids=()
        mapfile -t pids < <(component_pids "$name")
        (( ${#pids[@]} )) || { absent+=("$name"); continue; }

        for pid in "${pids[@]}"; do
            pgid=$(pgid_of "$pid")
            # A process with no group of its own was not started as a job, and
            # signalling -PGID would take this shell -- or the whole session --
            # down with it. Say so and leave it; a wrong kill here is worse than
            # a leftover.
            if [[ -z $pgid ]] || (( pgid <= 1 )) || [[ $pgid == "$self_pgid" ]]; then
                warn "$name: pid $pid is not in a process group of its own -- leaving it"
                continue
            fi
            # The port owner and the guard-pattern match are usually the same
            # process, so collapse by group rather than signalling it twice.
            seen=0
            for g in ${pgids[@]+"${pgids[@]}"}; do [[ $g == "$pgid" ]] && seen=1; done
            (( seen )) && continue
            names+=("$name"); pgids+=("$pgid")
        done
    done

    if (( ${#pgids[@]} == 0 )); then
        say "nothing to stop"
        (( ${#absent[@]} )) && note "not running: ${absent[*]}"
        return 0
    fi

    if (( DRY_RUN )); then
        say "dry run -- would signal ${#pgids[@]} process group(s)"
        for i in "${!pgids[@]}"; do note "${names[i]} -- process group ${pgids[i]}"; done
        return 0
    fi

    say "stopping ${#pgids[@]} component(s)"
    for i in "${!pgids[@]}"; do
        note "${names[i]} -- process group ${pgids[i]}"
        kill -TERM -"${pgids[i]}" 2>/dev/null
    done

    # The same ten seconds the in-run shutdown allows, for the same reason: the
    # worker drains the jobs it has already claimed before it goes.
    local waited=0 left
    while (( waited < 40 )); do
        left=0
        for i in "${!pgids[@]}"; do group_alive "${pgids[i]}" && (( left++ )); done
        (( left == 0 )) && break
        sleep 0.25
        (( waited++ ))
    done

    for i in "${!pgids[@]}"; do
        if group_alive "${pgids[i]}"; then
            warn "${names[i]} did not stop -- killing"
            kill -KILL -"${pgids[i]}" 2>/dev/null
        fi
    done

    # Confirm against the PORT, not the pid: a component is only really stopped
    # once it has let go of what the next run of this script needs.
    local rc=0
    for i in "${!pgids[@]}"; do
        name=${names[i]}
        p=${PORT[$name]:-}
        if [[ -n $p ]] && port_busy "$p"; then
            bad "$name: :$p is still served after the kill"
            rc=1
        else
            note "$name stopped"
        fi
    done
    (( ${#absent[@]} )) && note "not running: ${absent[*]}"
    return $rc
}

# ---------------------------------------------------------------------------
# Build phase
# ---------------------------------------------------------------------------

# Newest mtime (epoch seconds) among the given files/dirs, node_modules and
# .git excluded. Empty when nothing matches.
newest_mtime() {
    local p out
    out=$(for p in "$@"; do
        [[ -e $p ]] || continue
        find "$p" -type f \
            -not -path '*/node_modules/*' -not -path '*/.git/*' \
            -printf '%T@\n' 2>/dev/null
    done | sort -rn | head -1)
    echo "${out%%.*}"
}

file_mtime() { [[ -e $1 ]] && stat -c %Y "$1" || echo ""; }

# Does this component need compiling before it can run? Prints a reason on
# stdout when it does, nothing when it is current.
build_reason() {
    local name=$1 dir="$ROOT/${DIR[$name]}" artifact src_ts art_ts
    local -a sources

    case $name in
        spy)
            artifact="$dir/build/spy"
            sources=("$dir/main.go" "$dir/internal" "$dir/go.mod" "$dir/go.sum")
            ;;
        bot)
            artifact="$dir/dist/index.js"
            sources=("$dir/src" "$dir/tsconfig.build.json" "$dir/tsconfig.json" "$dir/package.json")
            ;;
        *) return 0 ;;   # nothing to build
    esac

    if [[ ! -e $artifact ]]; then
        echo "no build output at ${artifact#$ROOT/}"
        return 0
    fi
    (( FORCE_BUILD )) && { echo "--rebuild"; return 0; }

    src_ts=$(newest_mtime "${sources[@]}")
    art_ts=$(file_mtime "$artifact")
    [[ -n $src_ts && -n $art_ts && $src_ts -gt $art_ts ]] &&
        echo "sources changed since the last build"
    return 0
}

build_component() {
    local name=$1 dir="$ROOT/${DIR[$name]}" log="$LOG_DIR/$name.build.log" rc
    case $name in
        spy) ( cd "$dir" && bash ./build.sh ) ;;
        bot) ( cd "$dir" && npm run build ) ;;
        *)   return 0 ;;
    esac >"$log" 2>&1
    rc=$?
    if (( rc != 0 )); then
        bad "$name: build failed (exit $rc) -- last lines of ${log#$ROOT/}:"
        sed -e 's/^/      /' <(tail -n 20 "$log")
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# Preflight: everything that makes a component un-runnable, said up front
# rather than as a crash 20 seconds in.
# ---------------------------------------------------------------------------

preflight() {
    local name=$1 dir="$ROOT/${DIR[$name]}"

    [[ -d $dir ]] || { bad "$name: $dir does not exist"; return 1; }

    case $name in
        spy)
            command -v go >/dev/null || { bad "$name: go is not on PATH"; return 1; }
            if [[ -f $SPY_CONFIG_LOCAL ]]; then
                SPY_CONFIG=$SPY_CONFIG_LOCAL
            elif [[ -f $SPY_CONFIG_SYSTEM ]]; then
                SPY_CONFIG=$SPY_CONFIG_SYSTEM
                warn "$name: no spy/local.json, falling back to $SPY_CONFIG_SYSTEM"
            else
                bad "$name: no config (spy/local.json or $SPY_CONFIG_SYSTEM)"
                return 1
            fi
            ;;
        *)
            [[ -d $dir/node_modules ]] || {
                bad "$name: no node_modules in ${dir#$ROOT/} -- run npm install there"
                return 1
            }
            ;;
    esac

    case $name in
        city|worker)
            [[ -f $ROOT/website-city/.env ]] || {
                bad "$name: website-city/.env is missing (copy .env.example)"; return 1; }
            ;;
        nightly)
            [[ -f $ROOT/nightly/data/nightly.db ]] || {
                bad "$name: nightly/data/nightly.db is missing (npm run db:push && npm run db:seed)"; return 1; }
            ;;
        bot)
            [[ -f $ROOT/spy-discord-bot/conf/conf.json ]] || {
                bad "$name: spy-discord-bot/conf/conf.json is missing (copy conf/conf.example.json)"; return 1; }
            # An empty token is a login loop, not a startup error, so catch it here.
            grep -qE '"token"[[:space:]]*:[[:space:]]*"[^"]+' "$ROOT/spy-discord-bot/conf/conf.json" || {
                bad "$name: discord.token is empty in spy-discord-bot/conf/conf.json"; return 1; }
            ;;
    esac

    local pat=${GUARD_PAT[$name]:-} dup=
    if [[ -n $pat ]]; then
        dup=$(running_in_dir "$dir" "$pat" | head -1)
        if [[ -n $dup ]]; then
            warn "$name: already running as pid $dup -- skipping it"
            [[ $name == spy ]] && note "a second Spy would double-scan every server it is given"
            return 1
        fi
    fi

    local p=${PORT[$name]:-}
    if [[ -n $p ]] && port_busy "$p"; then
        local owner; owner=$(port_owner "$p")
        warn "$name: port $p is already in use${owner:+ by pid $owner} -- skipping it"
        case $name in
            worker) note "spy/bot will talk to the worker that is already there" ;;
            city)   note "two next dev servers would share .next and corrupt each other" ;;
        esac
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Run phase
# ---------------------------------------------------------------------------

# Astro >=7 detects "an agentic environment" (am-i-vibing reads CLAUDECODE,
# CURSOR_*, and friends) and silently runs `astro dev` as a DETACHED background
# process, printing a JSON banner and exiting 0 three seconds later. Under this
# runner that reads as "processing exited cleanly" while the dev server is still
# holding :3003 with nobody supervising it -- and Ctrl-C then leaves it behind.
# The env var is the only guard in astro's own code (`!process.env
# .ASTRO_DEV_BACKGROUND && isRunByAgent()`), so setting it pins the foreground
# whether a person or an agent ran this script. It only mislabels the
# `background:` field astro writes into its dev lock file.
export ASTRO_DEV_BACKGROUND=0

# The actual command per component. Runs after a cd into the component's dir.
run_cmd() {
    case $1 in
        city)       exec npm run dev -- --hostname 0.0.0.0 --port "${PORT[city]}" ;;
        processing) exec npm run dev -- --host 0.0.0.0 --port "${PORT[processing]}" ;;
        learn)      exec npm run dev -- --host 0.0.0.0 --port "${PORT[learn]}" ;;
        app)        exec npm run dev -- --host 0.0.0.0 --port "${PORT[app]}" ;;
        nightly)    exec npm run dev ;;  # its script already binds 0.0.0.0:3010
        worker)     exec ./start-workers.sh ;;
        shared)     exec npm run dev ;;
        spy)        exec ./build/spy -c "$SPY_CONFIG" ;;
        bot)        exec npm start ;;
    esac
}

declare -A PID=()      # component -> process-group leader pid
declare -A NAME_OF=()  # pid -> component
declare -A STARTED_AT=()
STARTED=()
FAILED=()

launch() {
    local name=$1 dir="$ROOT/${DIR[$name]}" log="$LOG_DIR/$name.log"
    local prefix="${COLOR[$name]}[$name]$RESET "
    : >"$log"
    (
        cd "$dir" || exit 127
        # The prefixer is a bash read loop rather than `tee | awk '{...;
        # fflush()}'`, because mawk (Debian's awk) does NOT honour fflush()
        # when its stdout is a regular file: run this as `./dev.sh > run.log`
        # -- or under anything that captures output -- and every component's
        # lines sit in a 4K buffer until the process dies, which is exactly
        # when you needed them. printf writes straight through, so the console
        # and the mirrored log stay live either way, and the prefix can carry
        # escape codes without sed/awk quoting rules getting a say.
        run_cmd "$name" 2>&1 |
            while IFS= read -r line || [[ -n $line ]]; do
                printf '%s\n' "$line" >>"$log"
                printf '%s%s\n' "$prefix" "$line"
            done
        exit "${PIPESTATUS[0]}"
    ) </dev/null &
    local pid=$!
    PID[$name]=$pid
    NAME_OF[$pid]=$name
    STARTED_AT[$name]=$SECONDS
    STARTED+=("$name")
}

# spy and bot open a TCP connection to the worker as their first act. Starting
# them into a closed port works -- both retry -- but the log then opens with
# errors that look like a fault and are not.
wait_for_worker() {
    (( WORKER_WAIT > 0 )) || return 0
    port_busy "${PORT[worker]}" && return 0
    say "waiting up to ${WORKER_WAIT}s for the worker's listener on :${PORT[worker]}"
    local waited=0
    while (( waited < WORKER_WAIT )); do
        port_busy "${PORT[worker]}" && { note "listener up after ${waited}s"; return 0; }
        sleep 1
        (( waited++ ))
    done
    warn "no listener on :${PORT[worker]} after ${WORKER_WAIT}s -- starting anyway (they retry)"
}

# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------

SHUTTING_DOWN=0

shutdown() {
    if (( SHUTTING_DOWN )); then
        # Second Ctrl-C: stop being polite.
        for n in "${STARTED[@]}"; do kill -KILL -"${PID[$n]}" 2>/dev/null; done
        exit 130
    fi
    SHUTTING_DOWN=1
    printf '\n'
    say "stopping ${#STARTED[@]} component(s) -- Ctrl-C again to kill"
    local n
    for n in "${STARTED[@]}"; do
        [[ -n ${PID[$n]:-} ]] || continue
        kill -TERM -"${PID[$n]}" 2>/dev/null || kill -TERM "${PID[$n]}" 2>/dev/null
    done
    # Give them ten seconds to unwind (the worker drains its claimed jobs),
    # then take the rest out.
    local waited=0
    while (( waited < 40 )); do
        local left=0
        for n in "${STARTED[@]}"; do group_alive "${PID[$n]}" && (( left++ )); done
        (( left == 0 )) && break
        sleep 0.25
        (( waited++ ))
    done
    for n in "${STARTED[@]}"; do
        group_alive "${PID[$n]}" && { warn "$n did not stop -- killing"; kill -KILL -"${PID[$n]}" 2>/dev/null; }
    done
}
trap shutdown INT TERM

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------

say "stack root $ROOT"

# --- stop ----------------------------------------------------------------
# A complete command on its own: --stop never builds, never launches, and never
# creates the log directory.
if (( STOP )); then
    stop_components
    exit $?
fi

mkdir -p "$LOG_DIR"

say "components: ${WANTED[*]}"

# --- build ---------------------------------------------------------------
RUNNABLE=()
if (( DO_BUILD )); then
    for name in "${WANTED[@]}"; do
        reason=$(build_reason "$name")
        [[ -n $reason ]] || continue
        say "building $name ($reason)"
        if build_component "$name"; then
            note "$name built"
        else
            FAILED+=("$name")
        fi
    done
fi

for name in "${WANTED[@]}"; do
    skip=0
    for f in ${FAILED[@]+"${FAILED[@]}"}; do [[ $f == "$name" ]] && skip=1; done
    (( skip )) && continue
    RUNNABLE+=("$name")
done

if (( BUILD_ONLY )); then
    (( ${#FAILED[@]} )) && { bad "build failures: ${FAILED[*]}"; exit 1; }
    say "build only -- nothing started"
    exit 0
fi

# --- preflight -----------------------------------------------------------
SPY_CONFIG=$SPY_CONFIG_LOCAL
GO=()
for name in "${RUNNABLE[@]}"; do
    if preflight "$name"; then GO+=("$name"); fi
done

if (( ${#GO[@]} == 0 )); then
    bad "nothing left to start"
    exit 1
fi

if (( DRY_RUN )); then
    say "dry run -- would start: ${GO[*]}"
    exit 0
fi

# --- launch --------------------------------------------------------------
for name in "${GO[@]}"; do
    case $name in
        spy|bot) wait_for_worker ;;
    esac
    say "starting $name  ${DIM}(${DIR[$name]})${RESET}"
    launch "$name"
done

printf '\n'
say "up: ${GO[*]}"
for name in "${GO[@]}"; do
    p=${PORT[$name]:-}
    [[ -n $p ]] && note "$name -> http://127.0.0.1:$p"
done
note "site: https://tmcdev.net  (nginx -> 3002 city, 3003 processing)"
note "stop: Ctrl-C here, or ./dev.sh --stop [component ...] from anywhere"
note "logs: ${LOG_DIR#$ROOT/}/<component>.log"
printf '\n'

# --- supervise -----------------------------------------------------------
ALIVE=${#GO[@]}
while (( ALIVE > 0 )); do
    wait -n -p exited_pid
    status=$?
    (( status == 127 )) && [[ -z ${exited_pid:-} ]] && break

    name=${NAME_OF[${exited_pid:-0}]:-}
    [[ -n $name ]] || continue
    (( ALIVE-- ))
    unset 'PID[$name]'

    if (( SHUTTING_DOWN )); then
        note "$name stopped"
        continue
    fi

    ran=$(( SECONDS - STARTED_AT[$name] ))
    p=${PORT[$name]:-}
    if (( status == 0 )) && [[ -n $p ]] && port_busy "$p"; then
        # It did not stop -- it detached. Say so, because "exited cleanly" plus a
        # port that is still answering is the confusing half of this failure.
        owner=$(port_owner "$p")
        warn "$name detached itself after ${ran}s -- :$p is still served${owner:+ by pid $owner}"
        note "this runner cannot stop it; ./dev.sh --stop $name will"
        FAILED+=("$name")
    elif (( status == 0 )); then
        warn "$name exited cleanly after ${ran}s"
    elif (( status == 143 || status == 130 || status == 129 )); then
        # 128 + SIGTERM/SIGINT/SIGHUP: something stopped this deliberately --
        # `./dev.sh --stop`, a kill by hand, or the terminal going away. Calling
        # that a failure trains you to ignore the line that is one.
        note "$name stopped by a signal after ${ran}s"
    else
        bad "$name exited with status $status after ${ran}s -- see ${LOG_DIR#$ROOT/}/$name.log"
        FAILED+=("$name")
    fi

    if (( STRICT )); then
        bad "--strict: taking the rest down"
        shutdown
        break
    fi
    (( ALIVE > 0 )) && note "still up: $ALIVE component(s); Ctrl-C to stop"
done

(( SHUTTING_DOWN )) || say "every component has exited"
if (( ${#FAILED[@]} )); then
    bad "failed: ${FAILED[*]}"
    exit 1
fi
exit 0
