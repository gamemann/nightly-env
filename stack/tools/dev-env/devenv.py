#!/usr/bin/env python3
"""TMC dev environment on the Pterodactyl panel and Wings node on this VM (was x-web / x-gs01). See ~/docs/dev-environment.md.

  devenv.py list                    our dev servers: id, identifier, port, state, memory
  devenv.py create [REPO...]        create the dev servers that do not exist yet (stopped; "multi" offers every game);
                                    for an existing one, correct TMC_GAMES/TMC_GAME
  devenv.py provision [--profile P | --backbone URL] [REPO...]
                                    point an installed server at a dev site and the dev CDN (idempotent)
  devenv.py power ACTION REPO...    start | stop | restart | kill (ours only, by external id tmc-dev-*)
  devenv.py console REPO [N]        last N lines of the server's console log (via the box)
  devenv.py uuid REPO               the server's uuid (its volume is /var/lib/pterodactyl/volumes/<uuid>)
  devenv.py ip REPO                 the IP the server is bound to (ip-plan.json)

Profiles (the dev site a server enrolls with; ~/docs/dev-environment.md): default https://tmcdev.net (tmc_dev),
games https://games.tmcdev.net (dev_games), claude https://claude.tmcdev.net (tmc_claude).
Keys are read from ~/.config/pterodactyl/{app_key,client_key} and never printed.
"""
import json, os, re, subprocess, sys, urllib.parse, urllib.request

PANEL = os.environ.get("DEVENV_PANEL", "https://panel.tmcdev.net")  # was http://x-web; now the panel on this VM
NODE_ID = 1  # node tmc-dev (Wings on this VM)
HOME = os.path.expanduser("~")
APP_KEY = open(f"{HOME}/.config/pterodactyl/app_key").read().strip()
CLIENT_KEY = open(f"{HOME}/.config/pterodactyl/client_key").read().strip()
PROFILES = {"default": "https://tmcdev.net", "games": "https://games.tmcdev.net", "claude": "https://claude.tmcdev.net"}
# tmcdevgames.net/content and /content-prod (dev01 nginx) proxy the dev and prod CDNs on the web player's own origin, because the CDNs send CORS for the prod site only.
CONTENT_URLS = ["https://tmcdevgames.net/content", "https://tmcdevgames.net/content-prod", "https://dev.dotgames.org/content", "https://dotgames.org/content"]
DEV_PUB = f"{HOME}/.config/dot/pack-dev.pub"  # the dev site's pack-signing public key (key id tmc-dev)
CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt"  # dev02's bundle, which includes the TMC Local Development CA

# repo, display name, max players. Game port is 6100 + 2*i, RCON one up.
GAMES = [("game-arena", "Arena"), ("game-zombie-zone", "Zombie Zone"), ("game-playground", "Playground"),
         ("game-g2gfast", "g2gfast"), ("game-hungario", "Hungario"), ("game-hide-n-seek", "Hide n Seek"),
         ("game-murder-mystery", "Murder Mystery"), ("mg-smash-copter", "Smash Copter"),
         ("mg-buses-from-hell", "Buses From Hell"), ("mg-wipeout", "Wipeout"), ("mg-deathrun", "Deathrun"),
         ("mg-dangerous-delivery", "Dangerous Delivery"), ("mg-look-at-me", "Look At Me"), ("mg-prop-hunt", "Prop Hunt"),
         ("multi", "Multi-game")]
# "multi" is one server offering every game above, switched by the game vote (dot-server-deploy docs/game-vote.md).
MULTI = "multi"
# Packs published under another id than the repo (dot-server-deploy reports these as retired ids).
CONTENT_IDS = {"mg-deathrun": "game-deathrun", "mg-prop-hunt": "game-prop-hunt"}


def game_env(repo):
    """TMC_GAMES and TMC_GAME for a server: its own pack, or every pack for MULTI."""
    cid = lambda r: "gamemann/" + CONTENT_IDS.get(r, r)
    if repo == MULTI:
        return {"TMC_GAMES": ",".join(cid(g) for g, _ in GAMES if g != MULTI), "TMC_GAME": cid(GAMES[0][0])}
    return {"TMC_GAMES": cid(repo), "TMC_GAME": cid(repo)}


def call(api, method, path, body=None, raw=None):
    key = APP_KEY if api == "application" else CLIENT_KEY
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    r = urllib.request.Request(f"{PANEL}/api/{api}{path}", method=method, data=data, headers={
        "Authorization": "Bearer " + key, "Accept": "application/json",
        "Content-Type": "text/plain" if raw is not None else "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=60) as f:
            out = f.read()
            if not out:
                return {}
            try:
                return json.loads(out)
            except ValueError:
                return out.decode()
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path}: HTTP {e.code} {e.read().decode()[:400]}")


def ours():
    out = {}
    for s in call("application", "GET", "/servers?per_page=100")["data"]:
        a = s["attributes"]
        if (a["external_id"] or "").startswith("tmc-dev-"):
            out[a["external_id"][8:]] = a
    return out


PLAN = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ip-plan.json")))


def port_of(repo):
    return PLAN[repo]["port"]


def ip_of(repo):
    return PLAN[repo]["ip"]


def egg_id():
    """The "dot-server" egg (imported from dot-server-deploy/deploy/pterodactyl-egg.json): ids differ per panel."""
    for n in call("application", "GET", "/nests?include=eggs")["data"]:
        for e in n["attributes"]["relationships"]["eggs"]["data"]:
            if e["attributes"]["name"] == "dot-server":
                return e["attributes"]["id"]
    raise SystemExit("egg \"dot-server\" is not imported on the panel")


def ensure_allocations(repos):
    """Allocations (game port and RCON port, on the server's IP) the plan needs and the node does not have yet."""
    have = {(a["attributes"]["ip"], a["attributes"]["port"])
            for a in call("application", "GET", f"/nodes/{NODE_ID}/allocations?per_page=500")["data"]}
    want = {}
    for r in repos:
        ip, p = ip_of(r), port_of(r)
        for q in (p, p + 1):
            if (ip, q) not in have:
                want.setdefault(ip, []).append(str(q))
    for ip, ports in want.items():
        call("application", "POST", f"/nodes/{NODE_ID}/allocations", {"ip": ip, "ports": ports})
        print("allocations", ip, ",".join(ports))


def memory_for(repo):
    """The zombie game's server peaks near 1 GB loading a map, and above 2.1 GB once the maps pack (54 maps) is mounted: 1800 MB was OOM-killed."""
    return {MULTI: 3500, "game-zombie-zone": 3500}.get(repo, 900)


def create(repos):
    ensure_allocations([g[0] for g in GAMES if not repos or g[0] in repos])
    allocs = {(a["attributes"]["ip"], a["attributes"]["port"]): a["attributes"]["id"]
              for a in call("application", "GET", f"/nodes/{NODE_ID}/allocations?per_page=500")["data"]}
    have = ours()
    for repo, name in GAMES:
        if repos and repo not in repos:
            continue
        if repo in have:
            a = have[repo]
            if a["limits"]["memory"] != memory_for(repo):
                call("application", "PATCH", f"/servers/{a['id']}/build", {"allocation": a["allocation"], **{
                     k: a["limits"][k] for k in ("swap", "io", "cpu", "disk", "threads")}, "memory": memory_for(repo),
                     "feature_limits": a["feature_limits"]})
                print(repo, "memory limit set to", memory_for(repo), "MB")
            want = game_env(repo)
            env = a["container"]["environment"]
            if any(env.get(k) != v for k, v in want.items()):
                c = a["container"]
                call("application", "PATCH", f"/servers/{a['id']}/startup", {"startup": c["startup_command"], "egg": a["egg"],
                     "image": c["image"], "environment": {**env, **want}, "skip_scripts": False})
                print(repo, "exists", a["identifier"], "games set to", want["TMC_GAMES"][:80])
            else:
                print(repo, "exists", a["identifier"])
            continue
        port = port_of(repo)
        env = {**game_env(repo), "TMC_MAP": "",
               "TMC_CONTENT_URL": ",".join(CONTENT_URLS), "TMC_GAMES_MODE": "hide", "TMC_NO_INSTALL": "",
               "TMC_PORT": "", "TMC_RCON_PORT": str(port + 1), "TMC_A2S_PORT": "", "TMC_QUERY_PORT": "",
               "TMC_QUERY_BIND": "*", "TMC_BIND": "0.0.0.0", "TMC_NAME": "TMC Dev - " + name,
               "TMC_MAX_PLAYERS": "32" if repo == MULTI else "16", "TMC_ALLOW_WEB": "1", "TMC_ALLOW_DESKTOP": "1", "TMC_ALLOW_MOBILE": "1",
               "TMC_WEB_LOADER": "", "TMC_WEB_BUILD": "", "TMC_CHANNEL": "latest", "TMC_AUTO_UPDATE": "when-needed",
               "DEPLOY_REPO": "https://github.com/gamespice-platform/server-deploy.git", "DEPLOY_BRANCH": "main",
               "TMC_VERBOSE": ""}
        body = {"name": "TMC Dev - " + name, "external_id": "tmc-dev-" + repo, "user": 1, "egg": egg_id(),
                "description": "TMC dev environment (~/projects/docs/dev-environment.md)",
                "docker_image": "ghcr.io/parkervcp/yolks:debian", "startup": "./server --port {{SERVER_PORT}}",
                "environment": env, "limits": {"memory": memory_for(repo), "swap": 0, "disk": 8000, "io": 500, "cpu": 100},
                "feature_limits": {"databases": 0, "allocations": 2, "backups": 0},
                "allocation": {"default": allocs[(ip_of(repo), port)], "additional": [allocs[(ip_of(repo), port + 1)]]},
                "start_on_completion": False}
        a = call("application", "POST", "/servers", body)["attributes"]
        print(repo, port, a["identifier"], "created (installing)")


def read(ident, path):
    out = call("client", "GET", f"/servers/{ident}/files/contents?file={urllib.parse.quote(path, safe='')}")
    return out if isinstance(out, str) else json.dumps(out)


def try_read(ident, path):
    try:
        return read(ident, path)
    except SystemExit:  # call() exits on any HTTP error; a missing file is a 404
        return ""


def write(ident, path, text):
    call("client", "POST", f"/servers/{ident}/files/write?file={urllib.parse.quote(path, safe='')}",
         raw=text.encode())


# Per game, the setting that files players' stats with the backbone (off by default everywhere).
STATS_SETTING = {"game-arena": "arena_stats_report", "game-zombie-zone": "zz_report_progress"}


def stats_cvar(text, repo, key):
    """overrides.yml with `cvars: {key: "1"}` under games.<repo>, adding what is missing."""
    if re.search(rf'(?m)^\s+{key}:', text):
        return text
    line = f'      {key}: "1"      # dev: file stats with the dev site\n'
    m = re.search(rf"(?m)^  {re.escape(repo)}:\n", text)
    if m:
        c = re.compile(r"(?m)^    cvars:\n").search(text, m.end())
        nxt = re.compile(r"(?m)^  \S").search(text, m.end())
        if c and (not nxt or c.start() < nxt.start()):
            return text[:c.end()] + line + text[c.end():]
        return text[:m.end()] + "    cvars:\n" + line + text[m.end():]
    g = re.search(r"(?m)^games:\n", text)
    entry = f"  {repo}:\n    cvars:\n" + line
    if g:
        return text[:g.end()] + entry + text[g.end():]
    return text.rstrip("\n") + "\ngames:\n" + entry


def arena_surf_ids(text):
    """overrides.yml with game-arena's surf packs under their published id, gamemann/arena-surf-dm-maps-<map>."""
    i = text.find("\n  game-arena:")
    if i < 0:
        return text
    j = text.find("\n  mg-wipeout:", i)
    j = len(text) if j < 0 else j
    blk = re.sub(r"(?m)^(\s+- gamemann/)(surf_\S+)", r"\1arena-surf-dm-maps-\2", text[i:j])
    return text[:i] + blk + text[j:]


def provision(repos, site):
    pub = open(DEV_PUB).read().strip() + "\n"
    bundle = open(CA_BUNDLE).read()
    for repo, a in sorted(ours().items()):
        if repos and repo not in repos:
            continue
        ident = a["identifier"]
        if a.get("status") == "installing" or call("client", "GET", f"/servers/{ident}")["attributes"].get("is_installing"):
            print(repo, "still installing; skipped")
            continue
        # content_urls: the file beats TMC_CONTENT_URL, so the list has to be in the file.
        yml = read(ident, "/cfg/server/server.yml")
        block = "content_urls:\n" + "".join(f'  - "{u}"\n' for u in CONTENT_URLS)
        yml2 = re.sub(r"(?m)^content_urls:\n(?:[ \t]+-.*\n)*", block, yml)
        # backbone: the dev site, for enrollment, the listing and sign-in. In the operator layer: an update rewrites cfg/addon.
        # trust: the dev site signs with tmc-dev; the prod key stays for the prod fallback origin.
        doc = json.loads(read(ident, "/data/content.json"))
        doc.setdefault("trusted_keys", {})["tmc-dev"] = pub
        # tmcdev.net has a certificate from the TMC Local Development CA, which the container does not trust.
        override = ('[network]\n\ntls/certificate_bundle_override="res://.runtime/dev-ca-bundle.crt"\n')
        # A game's cvar is registered when the pack's module loads, after server.yml is checked, so a top-level key there is
        # "unrecognised"; it goes under the game's cvars in cfg/server/content/overrides.yml. Drop the key an older run left.
        key = STATS_SETTING.get(repo)
        if key:
            yml2 = re.sub(rf"(?m)\n*# Dev: file players' stats with the dev backbone\.\n{key}: 1\n", "\n", yml2)
        changed = []
        if key:
            ov = try_read(ident, "/cfg/server/content/overrides.yml")
            ov2 = stats_cvar(ov, repo, key)
            if ov2 != ov:
                write(ident, "/cfg/server/content/overrides.yml", ov2)
                changed.append(f"cvar {key} in overrides.yml")
        if repo == "game-arena":
            ov = try_read(ident, "/cfg/server/content/overrides.yml")
            ov2 = arena_surf_ids(ov)
            if ov2 != ov:
                write(ident, "/cfg/server/content/overrides.yml", ov2)
                changed.append("arena surf pack ids in overrides.yml")
        if yml != yml2:
            write(ident, "/cfg/server/server.yml", yml2)
            changed.append("/cfg/server/server.yml")
        # A credential is only good on the site that issued it: on a site change drop it, so the box enrolls anew.
        old_site = re.search(r'backbone_url:\s*"?([^"\n]*)', try_read(ident, "/cfg/server/addon/dot_auth/auth.yml"))
        if not old_site or old_site.group(1).rstrip("/") != site:
            listing = json.loads(try_read(ident, "/data/listing.json") or "{}")
            listing.pop("integration_token", None)
            listing["backbone_url"] = site
            write(ident, "/data/listing.json", json.dumps(listing, indent=4) + "\n")
            changed.append(f"site {old_site.group(1) if old_site else '?'} -> {site}, token dropped")
        write(ident, "/cfg/server/addon/dot_auth/auth.yml", f'backbone_url: "{site}"\n')
        write(ident, "/data/content.json", json.dumps(doc, indent=4) + "\n")
        write(ident, "/.runtime/dev-ca-bundle.crt", bundle)
        write(ident, "/override.cfg", override)
        print(repo, ident, "provisioned", changed or "(cfg already dev)")


def power(action, repos):
    have = ours()
    for repo in repos:
        call("client", "POST", f"/servers/{have[repo]['identifier']}/power", {"signal": action})
        print(repo, action)
    if action in ("start", "restart"):  # enrollment needs the container's bridge IP mapped to its plan IP (natmap.sh)
        import time
        time.sleep(15)
        subprocess.run([os.path.join(os.path.dirname(os.path.abspath(__file__)), "natmap.sh")])


def listing():
    have = ours()
    for repo, _ in GAMES:
        a = have.get(repo)
        if not a:
            print(f"{repo:24} (not created)")
            continue
        if a["status"] == "installing":  # the panel answers 409 for an installing server's resources
            print(f"{repo:24} id={a['id']:<3} {a['identifier']} port={port_of(repo)} installing")
            continue
        r = call("client", "GET", f"/servers/{a['identifier']}/resources")["attributes"]
        print(f"{repo:24} id={a['id']:<3} {a['identifier']} ip={ip_of(repo)} port={port_of(repo)} state={r['current_state']:8} "
              f"mem={r['resources']['memory_bytes'] // 2**20}MB installing={a['status'] == 'installing'}")


def console(repo, n):
    uuid = ours()[repo]["uuid"]
    subprocess.run(["bash", "-c", f"sudo tail -n {n} /var/lib/pterodactyl/volumes/{uuid}/.dev-console.log 2>/dev/null"
                    f" || sudo docker logs --tail {n} {uuid} 2>&1"])


if __name__ == "__main__":
    args, site = sys.argv[1:], PROFILES["default"]
    for opt in ("--profile", "--backbone"):
        if opt in args:
            i = args.index(opt)
            val = args[i + 1] if i + 1 < len(args) else ""
            del args[i:i + 2]
            if opt == "--profile" and val not in PROFILES:
                raise SystemExit(f"unknown profile {val!r}: {', '.join(PROFILES)}")
            site = PROFILES[val] if opt == "--profile" else val.rstrip("/")
    cmd, rest = (args[0], args[1:]) if args else ("list", [])
    if cmd == "list":
        listing()
    elif cmd == "create":
        create(rest)
    elif cmd == "provision":
        provision(rest, site)
    elif cmd == "power":
        power(rest[0], rest[1:])
    elif cmd == "uuid":
        print(ours()[rest[0]]["uuid"])
    elif cmd == "ip":
        print(ip_of(rest[0]))
    elif cmd == "console":
        console(rest[0], int(rest[1]) if len(rest) > 1 else 60)
    else:
        print(__doc__)
        sys.exit(2)
