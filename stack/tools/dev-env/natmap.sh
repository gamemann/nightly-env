#!/bin/bash
# The site finds a server's row by the address a request comes from (enroll.ts: the request IP must equal the row's
# ip4). Containers sit behind pterodactyl_nw (172.18.0.x) and reach games.tmcdev.net on this same host, so nginx sees
# the bridge address, not the plan IP in ip-plan.json. This writes an nginx map from each running server container's
# bridge IP to its plan IP; games-tmc.conf forwards that as X-Forwarded-For / X-Real-IP. Re-run after a start/restart
# (a container's bridge IP changes). Dev only. Runs sudo itself (gamedev has passwordless root).
#   tools/dev-env/natmap.sh [--print]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=/etc/nginx/conf.d/tmc-dev-server-src.conf
body=$(python3 - "$HERE" <<'PY'
import json, subprocess, sys
here = sys.argv[1]
sys.path.insert(0, here)
import devenv
plan = json.load(open(here + "/ip-plan.json"))
have = devenv.ours()
lines = ["map $remote_addr $tmc_src_ip {", "    default $remote_addr;"]
for repo, p in sorted(plan.items()):
    a = have.get(repo)
    if not a: continue
    r = subprocess.run(["sudo", "-n", "docker", "inspect", a["uuid"], "--format",
                        "{{if .State.Running}}{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}{{end}}"],
                       capture_output=True, text=True)
    ip = r.stdout.strip()
    if ip: lines.append(f"    {ip} {p['ip']};  # {repo}")
lines.append("}")
print("\n".join(lines))
PY
)
[ "${1:-}" = --print ] && { echo "$body"; exit 0; }
{ echo "# Written by ~/godot/tools/dev-env/natmap.sh: container bridge IP -> plan IP (see that script)."; echo "$body"; } | sudo -n tee "$OUT" >/dev/null
sudo -n nginx -t 2>&1 | tail -1 && sudo -n nginx -s reload && echo "natmap: $(grep -c '#' "$OUT") lines"
