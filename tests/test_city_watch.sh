#!/usr/bin/env bash
# city-watch.sh: starts a closed port, leaves a healthy server alone, restarts a listening-but-silent one
# only after WATCH_FAILS bad probes, and recycles on memory. A stub city.sh stands in; python http.server
# (healthy) or a listening socket that never answers (wedged) stands in for the site. Usage: tests/test_city_watch.sh
set -u
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/stack/dev-env/city-watch.sh"
T=$(mktemp -d); PIDS=(); trap 'kill "${PIDS[@]}" 2>/dev/null; rm -rf "$T"' EXIT
cat > "$T/city.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUBLOG"
STUB
chmod +x "$T/city.sh"
pass=0; fail=0
ok() { echo "  ok   $1"; pass=$((pass+1)); }; bad() { echo "  FAIL $1"; fail=$((fail+1)); }
PORT=$((20000 + RANDOM % 20000))
once() { env STUBLOG="$T/log" CITY_SH="$T/city.sh" WATCH_STATE_DIR="$T" WATCH_PORT=$PORT WATCH_TIMEOUT=1 "$@" bash "$W" t >/dev/null 2>&1; }
reset() { rm -f "$T/log" "$T"/city-watch-*.fails; }
logline() { cat "$T/log" 2>/dev/null | tr '\n' '|'; }
reset; once; [ "$(logline)" = "t|" ] && ok "closed port starts" || bad "closed port: [$(logline)]"
mkdir "$T/www"; python3 -m http.server "$PORT" --directory "$T/www" >/dev/null 2>&1 & PIDS+=($!); sleep 1
reset; once WATCH_URL="http://127.0.0.1:$PORT/"; [ -z "$(logline)" ] && ok "healthy left alone" || bad "healthy: [$(logline)]"
reset; once WATCH_URL="http://127.0.0.1:$PORT/" WATCH_RSS_MB=1; [ "$(logline)" = "t --stop|t|" ] && ok "memory ceiling recycles" || bad "memory: [$(logline)]"
kill "${PIDS[@]}"; wait 2>/dev/null; PIDS=(); sleep 1
python3 - "$PORT" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); time.sleep(60)
PY
PIDS+=($!); sleep 1
reset; once; once
[ -z "$(logline)" ] && ok "wedged: no restart before 3 probes" || bad "early restart: [$(logline)]"
once; [ "$(logline)" = "t --stop|t|" ] && ok "wedged: restart on 3rd probe" || bad "wedged: [$(logline)]"
echo "passed $pass, failed $fail"; [ "$fail" = 0 ]
