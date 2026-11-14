Scripts that run my game-development fleet: a handful of Claude Code agents that build, test and benchmark a set of Godot 4 games and addons around the clock, spread over a few machines. Source of truth lives on the `core` user at `/home/core/projects/nightly-env`; the live paths are symlinks created by `install.sh`.

## Environment

The machines are virtual machines and a laptop in my homelab. The hardware, hypervisor and networking are documented in my [homelab repo](https://github.com/gamemann/my-home-lab).

| Role | What it is | Specs | Used for |
|---|---|---|---|
| Development VM | The main box. Agents edit code, run git and orchestrate everything from here. | 20 vCPUs, about 40 GB RAM, 3 TB NVMe, Debian 13, no GPU | Editing, quick tests, the nightly board, git pushes |
| Build and test VM | A larger VM on a Dell Precision tower with 128 GB of RAM. It never hosts development. | 40 vCPUs, 112 GB RAM, 320 GB disk, Debian 13, no GPU | Godot test suites, Rust and TypeScript builds, Playwright, headless benchmarks |
| Windowed GPU machines | Laptop and staging boxes with a real GPU and a display. | Laptop-class GPU | Windowed performance benchmarks, screenshots and video capture |

The development VM is the one the agents live on. Anything heavy (suites, builds, imports) is pushed to the build VM by `hv`, so the development VM stays responsive. Windowed work goes to the GPU machines, because headless Godot cannot measure rendering or audio.

Specs are approximate and change as I move things around. The scripts never hardcode hostnames; see [Where private values live](#where-private-values-live).

## What is in here

| Dir | What |
|---|---|
| `bin/` | `hv` (offload Godot suites and imports to the build VM or a GPU machine), `heavy` (queue wrapper that limits concurrent jobs, installed as root), `fleet-watchdog.sh` (kills stuck Godot jobs and writes a health file), `phbuild` (remote builds), `ph-smoke` |
| `godot/` | Game-dev tools: `gpu.sh` (offload to a GPU machine), `attach-shot.sh`, `capture-reviews.sh`, `deploy-web-shell.sh`, `push-github.sh`, `NOTES.md` |
| `stack/` | Web dev stack helpers: `dev.sh`, `kill-intensive.sh`, `dev-env/*`, `scripts/*` |
| `systemd/` | User units for the nightly panel and the dev stack |
| `cron/` | Crontabs for the two users (apply by hand after review) |
| `docs/` | Instruction files the agents read (`gamedev-CLAUDE.md`, `stack-CLAUDE.md`) |

## Install

```
sudo -u gamedev /home/core/projects/nightly-env/install.sh gamedev
sudo -u core    /home/core/projects/nightly-env/install.sh core
sudo install -m755 /home/core/projects/nightly-env/bin/heavy /usr/local/bin/heavy   # root
```

Existing files are kept as `*.pre-nightly-env`. The `gamedev` user reads through the symlinks (`/home/core` is traversable). Commit and push as `core`: `sudo -u core git -C /home/core/projects/nightly-env ...`.

## Where private values live

This repository is public, so hostnames, IPs, credentials and key paths are not stored here. Scripts read them from a private env file outside the repo, `~/.config/nightly-env/env` (override with `NIGHTLY_ENV_FILE`, mode 600), for example:

```
DEVDB_HOST=<dev database host/IP>                                   # bin/ph-smoke
FLEET_BOXES="staging:user@host staging02:user@host ph:user@host"    # bin/fleet-watchdog.sh
```

The list of private files to back up is `manifest-private-files.tsv` (git-ignored; see `manifest-private-files.example.tsv`). `.gitignore` blocks env files, keys, certificates and databases. Edit scripts here (the symlink path is fine), then commit and push.
