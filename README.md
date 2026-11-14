Scripts that run my game-development fleet (built around [nightly](https://github.com/gamemann/nightly)): a handful of Claude Code agents that build, test and benchmark a set of Godot 4 games and addons around the clock, spread over a few machines. Source of truth lives on the `core` user at `/home/core/projects/nightly-env`; the live paths are symlinks created by `install.sh`.

## Environment

Two virtual machines and two GPU machines in my homelab.

| Role | Machine | Specs | Used for |
|---|---|---|---|
| Development VM | VM on **Xtreme** (Proxmox, Intel i7-13700K, 64 GB DDR4, 4 TB NVMe) | 20 vCPUs, about 40 GB RAM, 3 TB NVMe, Debian 13, no GPU | Agents edit code, run git and orchestrate everything from here; quick tests, the nightly board |
| Build and test VM | VM on **Powerhorse** (Dell Precision Tower 7810, 2x Xeon E5-2670 v3, 128 GB DDR4, Proxmox) | 40 vCPUs, 112 GB RAM, 320 GB disk, Debian 13, no GPU | Godot test suites, Rust and TypeScript builds, Playwright, headless benchmarks |
| GPU desktop | **SpyKids**, a desktop | Intel i7-8700K, RTX 2070, 32 GB DDR4, 2 TB SATA SSD (Debian 13) | Windowed performance benchmarks, screenshots, video capture |
| GPU laptop | **Staging01**, an ASUS TUF Gaming A17 | AMD Ryzen 7 4800H (8c/16t), GTX 1660 Ti, 16 GB DDR4, 1 TB NVMe (Linux Mint) | Windowed benchmarks and captures, shared with me while I use it |

The full hardware list, hypervisors and networking are in my [homelab repo](https://github.com/gamemann/my-home-lab). The development VM is where the agents live. Anything heavy (suites, builds, imports) is pushed to the build VM by `hv`, so the development VM stays responsive. Windowed work goes to the GPU machines, because headless Godot cannot measure rendering or audio.

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

These scripts sit on top of [nightly](https://github.com/gamemann/nightly), the web panel and CLI that schedules the agents, tracks their tasks and lets them coordinate on a shared board. Install that first.

1. Set up the panel (Node.js and npm required):

```
git clone https://github.com/gamemann/nightly ~/stack/nightly
cd ~/stack/nightly
npm install
npm run db:push
npm run build
```

2. Keep it running with the included user unit, then open the panel on port 3010 and add a runner script, a prompt and a schedule (the nightly README walks through it):

```
mkdir -p ~/.config/systemd/user
cp deploy/nightly-panel.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now nightly-panel
loginctl enable-linger $USER
```

3. Clone this repository and link its scripts into place. My setup uses two Linux users, `core` for the web projects and `gamedev` for the Godot games, so there is one install per user; adjust the paths in `install.sh` to your own layout:

```
git clone https://github.com/gamemann/nightly-env /home/core/projects/nightly-env
sudo -u gamedev /home/core/projects/nightly-env/install.sh gamedev
sudo -u core    /home/core/projects/nightly-env/install.sh core
sudo install -m755 /home/core/projects/nightly-env/bin/heavy /usr/local/bin/heavy   # root
```

4. Create the private env file described below (hostnames and addresses of your own machines).

Existing files are kept as `*.pre-nightly-env`. The `gamedev` user reads through the symlinks (`/home/core` is traversable). Commit and push as `core`: `sudo -u core git -C /home/core/projects/nightly-env ...`.

## Where private values live

This repository is public, so hostnames, IPs, credentials and key paths are not stored here. Scripts read them from a private env file outside the repo, `~/.config/nightly-env/env` (override with `NIGHTLY_ENV_FILE`, mode 600), for example:

```
DEVDB_HOST=<dev database host/IP>                                   # bin/ph-smoke
FLEET_BOXES="staging:user@host staging02:user@host ph:user@host"    # bin/fleet-watchdog.sh
```

The list of private files to back up is `manifest-private-files.tsv` (git-ignored; see `manifest-private-files.example.tsv`). `.gitignore` blocks env files, keys, certificates and databases. Edit scripts here (the symlink path is fine), then commit and push.
