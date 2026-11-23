<p align="center"><img src="docs/banner.png" alt="Nightly env and scripts" width="100%"></p>

The scripts, cron jobs and units that run the TMC game-development fleet around [Nightly](https://github.com/gamemann/nightly): Claude Code agents that build, test and benchmark the FC (Fatal Contact), Playlot and Airdrift games and the GS (GameSpice) addons around the clock. The source of truth lives on the `core` user at `/home/core/projects/nightly-env`; the live paths are symlinks made by `install.sh`. The repository is public, so it holds no hostnames, addresses or credentials (see [Private values](#private-values)).

## Contents

| Section | What |
|---|---|
| [Environment](#environment) | The machines the scripts spread work over |
| [bin](#bin) | Job queue, offload to build and GPU boxes, watchdog, remote builds |
| [godot](#godot) | Game-tree tools: GPU offload, screenshots, worktree pruning, publishing |
| [stack](#stack) | Web dev stack: dev servers, profiles, checks, dev game servers |
| [cron and systemd](#cron-and-systemd) | Scheduled jobs and user units |
| [Installers](#installers) | `install.sh`, `install-nightly.sh`, `restore.sh`, `manifest-repos.tsv` |
| [Tests](#tests) | Shell tests for `heavy` and `hv` |
| [Private values](#private-values) | Where hostnames and keys live |
| [Install and restore](#install-and-restore) | Setting up or rebuilding a box |

## Environment

One development VM plus a build VM and two GPU machines in the homelab (specs are approximate; hardware details are in the [homelab repo](https://github.com/gamemann/my-home-lab)).

| Role | Machine | Used for |
|---|---|---|
| Development VM | VM on Xtreme (Proxmox, i7-13700K, 64 GB) | Agents edit code, run git and orchestrate; the Nightly panel |
| Build and test VM | VM on Powerhorse (2x Xeon E5-2670 v3, 128 GB) | Godot suites, Rust and TypeScript builds, Playwright, headless benchmarks |
| GPU desktop | SpyKids (i7-8700K, RTX 2070) | Windowed benchmarks, screenshots, video capture |
| GPU laptop | Staging01 (Ryzen 7 4800H, GTX 1660 Ti) | Windowed benchmarks and captures |

Heavy work is pushed off the development VM by `hv`; windowed work goes to the GPU machines because headless Godot cannot measure rendering or audio.

## bin

Queueing and offload. `heavy` is installed as root; the rest link into `~gamedev/bin` or `~core/bin`.

| Script | What it does | Usage |
|---|---|---|
| `heavy` | Memory-aware job queue: one build or suite at a time, scoped memory cap, wall-clock ceiling | `heavy [--lane build\|check] -- <cmd>`, `heavy --status` |
| `hv` | Runs a suite or scene through `heavy` in the one form the GPU boxes can take; retries an infrastructure kill on another box | `hv <dir> game\|scene\|import\|local ...`, `hv baseline <repo>` |
| `fleet-watchdog.sh` | Cron job: kills hung headless Godot jobs, keeps the heavy lane moving, writes a health file | cron, every 3 min |
| `addon-fresh` | Stale-addon guard: reports addon checkouts behind origin/main after a parse failure | `addon-fresh [game-dir]` |
| `phbuild` | Runs a heavy web command (tsc, lint, vitest, build) on the build VM | `phbuild <worktree> <cmd...>` |
| `ph-smoke` | Route smoke sweep of the site in production mode on the build VM | `ph-smoke [claude\|default\|games]` |

The `bin/*.bak-*` files are dated copies kept for rollback. Details: [docs/gamedev-CLAUDE.md](docs/gamedev-CLAUDE.md).

## godot

Tools for the game tree under `~gamedev/godot`.

| Script | What it does | Usage |
|---|---|---|
| `gpu.sh` | Launcher for the family's GPU offload (`gs-bootstrap/tools/gpu.sh`) | `gpu.sh capacity` |
| `attach-shot.sh` | Attaches a screenshot to a Nightly item | `attach-shot.sh <item> <png> [note]` |
| `capture-reviews.sh` | Sends animation clips of a game to the Nightly reviews page | `capture-reviews.sh <game> [--all\|--dry-run]` |
| `deploy-web-shell.sh` | Manual fallback for publishing the web shell | `deploy-web-shell.sh` |
| `push-github.sh` | Pushes every `gs-*` and `game-*` repository | `push-github.sh` |
| `prune-wt.sh` | Sweeps merged, clean worktrees | `prune-wt.sh [-n]` |
| `prune-wt-links.sh` | Removes dangling worktree symlinks | `prune-wt-links.sh [-n]` |
| `NOTES.md` | Layout notes for the game tree | |

## stack

Web dev stack helpers (user `core`).

| Script | What it does | Usage |
|---|---|---|
| `dev.sh` | Brings the dev stack up with one command | `dev.sh [city processing ...\|all\|--stop\|--list]` |
| `kill-intensive.sh` | Kills processes over 512 MB RSS (not sshd or systemd) | `kill-intensive.sh` |
| `dev-env/city.sh`, `processing.sh`, `games-stack.sh`, `profile.sh` | Per-profile dev servers: `default`, `games`, `claude` | `city.sh [profile] [--fg\|--stop\|--status]` |
| `scripts/check-layout-sync.sh` | Validates the shared site-nav and its consumers | `check-layout-sync.sh` |
| `scripts/claude-usage.sh` | Claude plan usage for the account | `claude-usage.sh` |
| `tools/dev-env-check.sh` | End-to-end check of the dev chain | `dev-env-check.sh [--profile P] [--browser]` |
| `tools/gpu-lanes-check.sh` | Checks that the GPU boxes run jobs side by side | `gpu-lanes-check.sh` |
| `tools/dev-env/devenv.py` | Manages dev game servers on the Pterodactyl panel | `devenv.py list\|create` |
| `tools/dev-env/servers.sh`, `natmap.sh`, `web_check.sh` | Dev server lifecycle, nginx address map, Playwright checks | see script headers |

## cron and systemd

| File | What |
|---|---|
| `cron/gamedev.crontab` | Queue watcher, Pterodactyl schedule, `fleet-watchdog.sh` every 3 minutes |
| `cron/core.crontab` | Core user's jobs |
| `systemd/stack-dev.service` | User unit keeping the city and processing dev servers up |

Apply crontabs by hand after review: `sudo -u gamedev crontab cron/gamedev.crontab`. The Nightly panel itself is installed by `install-nightly.sh`, not by a unit here.

## Installers

| File | What |
|---|---|
| `install.sh` | Links scripts into their live paths for one user; existing files are kept as `*.pre-nightly-env` |
| `install-nightly.sh` | Machine-level Nightly parts: nightly-node daemon, nginx site, scc |
| `restore.sh` | Clones every repo in the manifest for one user, then runs `install.sh` |
| `manifest-repos.tsv` | user, path, remote, branch for every checkout (`link` rows are symlinks to renamed checkouts) |
| `manifest-private-files*.tsv` | Private files to back up (the real one is git-ignored) |

## Tests

```
tests/test_heavy_shared_files.sh
tests/test_hv_infra_retry.sh
```

## Private values

Hostnames, IPs and key paths come from `~/.config/nightly-env/env` (mode 600; override with `NIGHTLY_ENV_FILE`), outside the repo:

```
DEVDB_HOST=<dev database host>
FLEET_BOXES="staging:user@host staging02:user@host ph:user@host"
```

`.gitignore` blocks env files, keys, certificates and databases. Recovery steps: [docs/RECOVERY.md](docs/RECOVERY.md). Agent instruction files: [docs/gamedev-CLAUDE.md](docs/gamedev-CLAUDE.md), [docs/stack-CLAUDE.md](docs/stack-CLAUDE.md).

## Install and restore

Fresh box, as `core` after it has a GitHub SSH key:

```
git clone git@github.com:gamemann/nightly-env.git /home/core/projects/nightly-env
cd /home/core/projects/nightly-env
sudo -u core    ./restore.sh core      # clone repos, link scripts
sudo -u gamedev ./restore.sh gamedev
sudo install -m755 bin/heavy /usr/local/bin/heavy
./install-nightly.sh --planet --dry-run   # then without --dry-run; --station on offload boxes
```

Then restore the private files, apply the crontabs and enable the units (`systemctl --user enable --now stack-dev`). Only linking, no cloning: `./install.sh core|gamedev`. Full steps: [docs/RECOVERY.md](docs/RECOVERY.md).
