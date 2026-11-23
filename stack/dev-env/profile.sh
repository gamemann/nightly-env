# Sourced by the dev-env scripts: load a dev profile's environment over website-city's .env.
#   default  .env alone: tmc_dev, tmcdev.net, city :3002, processing :3003 (what ~/stack/dev.sh runs)
#   games    + .env.dev-games: dev_games, games.tmcdev.net, city :3013, processing :3014
#   claude   + .env.claude: tmc_claude, claude.tmcdev.net, city :3012, processing :3015
# A profile file holds only what differs (DATABASE_URL, CH_DB, URLs, NEXT_DIST_DIR, ports), mode 0600.
# Exported keys win over .env in Next, Prisma (dotenv) and `node --env-file`, so .env itself is never edited.
STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CITY_DIR="$STACK/website-city"
PROCESSING_DIR="$STACK/website-processing"
LOG_DIR="$STACK/.dev-logs"

profile_file() {
    case "$1" in
        default) echo "" ;;
        games) echo "$CITY_DIR/.env.dev-games" ;;
        claude) echo "$CITY_DIR/.env.claude" ;;
        *) echo "unknown profile '$1' (default, games, claude)" >&2; return 2 ;;
    esac
}

load_profile() {
    PROFILE="${1:-default}"
    local f; f=$(profile_file "$PROFILE") || exit 2
    CITY_PORT=3002; PROCESSING_PORT=3003
    if [ -n "$f" ]; then
        [ -f "$f" ] || { echo "$PROFILE: $f is missing (see website-city docs/dev/profiles.md)" >&2; exit 1; }
        [ "$(stat -c %a "$f")" = 600 ] || echo "warning: $f is not mode 600" >&2
        set -a; . "$f"; set +a
    fi
    # Which database, without the credentials.
    DB_NAME=$(grep -m1 '^DATABASE_URL=' "${f:-$CITY_DIR/.env}" | sed -E 's#.*/([A-Za-z0-9_]+)(\?.*)?"?$#\1#')
    SITE_URL="${PUBLIC_URL:-https://tmcdev.net}"
    export PROFILE CITY_PORT PROCESSING_PORT
}

port_busy() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }
port_pid() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2; }

# start_bg NAME DIR CMD...: detached in its own session and process group, logging to .dev-logs/NAME.log.
start_bg() {
    local name=$1 dir=$2; shift 2
    mkdir -p "$LOG_DIR"
    # Own cgroup per dev server: a leaking next dev is killed at DEV_MEM_MAX, not the VM.
    # sudo -u core / ssh leave these unset, which makes systemd-run fail and the server never start
    [ -n "${XDG_RUNTIME_DIR:-}" ] || { [ -d "/run/user/$(id -u)" ] && export XDG_RUNTIME_DIR="/run/user/$(id -u)"; }
    [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || { [ -S "/run/user/$(id -u)/bus" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"; }
    local cap=(); [ -S "/run/user/$(id -u)/bus" ] && cap=(systemd-run --user --scope --quiet --collect --unit="dev-$name-$$"
        -p MemoryMax="${DEV_MEM_MAX:-8G}" -p MemorySwapMax=0 -p CPUWeight=50)
    # No --max-old-space-size: next dev's growth is Turbopack native memory, not V8 heap, so a heap cap does nothing.
    # Keep the previous log: the watchdog restarts within a minute and used to overwrite the crash evidence.
    [ -s "$LOG_DIR/$name.log" ] && mv -f "$LOG_DIR/$name.log" "$LOG_DIR/$name.prev.log"
    ( cd "$dir" && exec setsid "${cap[@]}" "$@" ) >"$LOG_DIR/$name.log" 2>&1 </dev/null &
    echo "$name: started (pid $!), log $LOG_DIR/$name.log"
}

# stop_port NAME PORT: TERM the whole process group that owns the port (npm wraps next/astro), KILL after 10 s.
stop_port() {
    local name=$1 port=$2 pid pgid i
    pid=$(port_pid "$port")
    [ -n "$pid" ] || { echo "$name: nothing on :$port"; return 0; }
    pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
    if [ -z "$pgid" ] || [ "$pgid" -le 1 ]; then kill -TERM "$pid"; else kill -TERM -- -"$pgid"; fi
    for i in $(seq 40); do port_busy "$port" || break; sleep 0.25; done
    port_busy "$port" && { kill -KILL -- -"$pgid" 2>/dev/null || kill -KILL "$pid"; }
    echo "$name: stopped :$port"
}

# wait_http NAME URL SECONDS: until the server answers anything at all.
wait_http() {
    local i
    for i in $(seq "$3"); do
        curl -s -o /dev/null -m 5 "$2" && { echo "$1: answering at $2"; return 0; }
        sleep 1
    done
    echo "$1: no answer at $2 after $3 s" >&2; return 1
}
