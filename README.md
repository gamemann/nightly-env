# nightly-env

Dev environment scripts for the nightly/fleet setup (dev02 + PH build VM). Source of truth lives here on the `core` user at `/home/core/projects/nightly-env`; the live paths are symlinks created by `install.sh`.

| Dir | What |
|---|---|
| `bin/` | `hv` (offload Godot suites/imports to PH/staging), `heavy` (slot queue wrapper, root-installed copy), `fleet-watchdog.sh` (kills stuck godot jobs, writes `.fleet/health.txt`), `phbuild`, `ph-smoke` |
| `godot/` | gamedev-side tools: `gpu.sh` (box offload), `attach-shot.sh`, `capture-reviews.sh`, `deploy-web-shell.sh`, `push-github.sh`, `NOTES.md` |
| `stack/` | core-side dev stack: `dev.sh`, `kill-intensive.sh`, `dev-env/*`, `scripts/*` |
| `systemd/` | core user units (`nightly-panel`, `stack-dev`) |
| `cron/` | crontabs for gamedev and core (apply by hand after review) |
| `docs/` | agent instruction files (`gamedev-CLAUDE.md`, `stack-CLAUDE.md`) |

## Install
```
sudo -u gamedev /home/core/projects/nightly-env/install.sh gamedev
sudo -u core    /home/core/projects/nightly-env/install.sh core
sudo install -m755 /home/core/projects/nightly-env/bin/heavy /usr/local/bin/heavy   # root
```
Existing files are kept as `*.pre-nightly-env`. The gamedev user reads through the symlinks (`/home/core` is traversable); commit and push as `core`: `sudo -u core git -C /home/core/projects/nightly-env ...`.

## Rules
No secrets, tokens or keys in this repo. Env files stay on the box. Edit scripts in this repo (via the symlink path is fine), then commit and push.
