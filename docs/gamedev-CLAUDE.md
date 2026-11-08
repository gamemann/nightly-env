# game-dev

All game-development assets, organised by engine. `godot/` (Godot 4.7.2) is the only engine so far; Unreal and Unity would get sibling directories with the same one-repo-per-project rule.

**Each subdirectory of `godot/` is its own Git repository**, cloned individually. `game-dev/` and `godot/` are not repositories. Anything shared lives in an addon (usually `dot-core`) or is duplicated on purpose. `godot/NOTES.md` has the layout rules.

## Machines: game dev is on dev02, the web stack is on dev01

**This VM is `x-tmc-dev02`, the home of TMC game development** (since 2026-10-14): `~/godot`, `~/docs`. `~/stack/game-dev` on dev01 is a stale old copy; never edit or test there. Passwordless `sudo` works here.

**`x-tmc-dev01` is the app and web VM** (`website-city`, `website-processing`, `website-learn`, `tmc-app`, `nightly` and the rest, in `~/stack/`). Reach it with `ssh dev01` (key `~/.ssh/dev01`, user `christian`, 10.50.0.185). **You have full access to dev01** (read, edit, run, restart services, query databases), and dev01's sessions have the same access here. When game work needs the web environment (backbone API, a database, the site), use dev01's; never stand up a second copy here.

- **The site**: `tmcdev.net` (and `claude.tmcdev.net`, `tmcdevgames.net`) is nginx on dev01 in front of website-city :3002 and website-processing :3003. A 502 means those dev servers are down: `~/stack/dev.sh city processing` on dev01. Nightly panel: `http://x-tmc-dev01:3010`.
- **Databases**: PostgreSQL (:5432, `tmc_dev`, credentials in dev01's `~/stack/website-city/.env`) and Redis (:6379) are on dev01's loopback only: `ssh -N -L 5432:127.0.0.1:5432 -L 6379:127.0.0.1:6379 dev01`, then `127.0.0.1`. Never copy a secret from that `.env` onto this machine.
- **The agent board** (dev01's `~/stack/CLAUDE.md`) coordinates both VMs: `ssh dev01 ~/stack/nightly/bin/nightly agent join <name> --task "..."`, then `agent claim <name> dev02:godot/<repo>` before changing a repo here (anything in dev01's `~/stack` by its own path), `agent release <name> <key>` after, and `agent say` / `agent inbox` to hand over or warn. Read the inbox now and then. **Claims are listed two ways at the top of `agent board`**, `holds: dev02:godot/X` and `dev02:godot/X  by NAME`: check both (`sed -n '1,/^#[0-9]/p'`), or you will edit a held repo.

## Spawning agents: pick the cheapest model that can do it

Usage is mostly context re-read on every call, so agent size and model are the cost. Use the typed agents in `~/.claude/agents/`, never a bare general-purpose spawn (a hook refuses one without `model`): **`scout`** (haiku) for read-only lookups, **`researcher`** (sonnet) for web, assets and licences, **`builder`** (sonnet) for one scoped change in **one** repo, **`specialist`** (opus) only for hard cross-addon problems or after a builder failed. "Do X in every game" is one builder per game, never one agent for all. Ask agents for short reports and keep test logs out of context (tail/grep them). Start a fresh orchestrator session per batch of work instead of one that runs for days; the board and git hold the state. Before calling a large change (or one in a shared addon, auth or security) done, have a fresh agent that did not write it review the diff against the task and report correctness gaps only; a reviewer asked for gaps always finds some, so skip the style ones.

**When compacting**, keep the repos claimed on the board, every commit made (repo and hash) and whether it is pushed, the branch each repo is on, and the exact checks still to run.

**The orchestrator itself runs on Sonnet for routine batches**: handing known tasks to builders, reading their reports, re-spawning a failed one, keeping the board current. Start those sessions with `claude --model sonnet` (or `/model sonnet`). Use Opus for the session when the batch is design, cross-addon planning, or triage of a bug nobody understands yet, and switch with `/model` mid-session when a routine batch turns into one of those. The orchestrator was about a quarter of all usage when it always ran on Opus. **The nightly runner is the same split, fixed in place**: its coordinator runs on Sonnet (`run.sh`, `NIGHTLY_MODEL`) and spawns its builders with `model: "opus"` (`nightly.md`, "Sub-agents"), while interactive sessions keep Opus as the default. `~/stack/nightly/scripts/agent-usage.py` on dev01 shows the split per model and agent type on both VMs (`--check` flags misuse); the weekly `chk-agent-usage` runs it.

## Memory: builds and suites go through `heavy`

Both VMs ran out of RAM when parallel agents built and tested at the same time, and the host killed x-tmc-dev01 (2026-10-16). Every build, smoke/verify run, Playwright run, type-check, cargo build and Godot run goes through **`heavy -- <command>`** on the VM that runs it. A Bash hook refuses the bare command and prints the rewrite. `heavy` queues jobs per VM (two checks; one build or suite on dev01, two on dev02, the second only while 5 GB is free) and waits for free memory. Put long runs in `run_in_background`; `heavy --status` shows the queue. Run **at most three sub-agents at a time, and at most two of them builders** (or anything else that runs suites): `heavy` runs at most two suites (dev02, when memory allows), so a third builder mostly waits in the queue while its prompt cache expires and must be re-written. Everything the `christian` user runs is also capped (`user-1000.slice` MemoryMax), so a job that overshoots kills itself, not the VM. Details: `~/stack/nightly/scripts/heavy/README.md` on x-tmc-dev01.

## The projects

Names only, so you know what exists; what each is and what is unusual about it is in [docs/projects.md](docs/projects.md), the addons' responsibilities and dependency shape in [docs/family.md](docs/family.md), and the one list of repositories is `dot-bootstrap/projects.tsv`. Read the project's own `CLAUDE.md` before working in it.

- **Foundation and tooling**: `dot-core` (DotResult, DotNodeRef, DotRegistry, DotConfig, DotLog, `random/`, `loading/`, the parse tool), `dot-log`, `dot-sql`, `dot-ci` (**public** shared CI), `dot-bootstrap`, `dot-map-convert` (the one BSP map converter and original-to-free-replacement tables; Python, no Godot project), `dot-serve`, `dot-server-deploy` (TMC's server tool and client shell; ships no game, every game is a signed dot-cloud pack).
- **Networking and server**: `dot-net`, `dot-server`, `dot-server-query`, `dot-server-security`, `dot-game` (the server and client wiring every game repeats, `DotGameClient`), `dot-peer-to-peer`, `dot-cloud`, `dot-browser`.
- **Identity and platform**: `dot-auth`, `dot-user`, `dot-user-avatar`, `dot-platform`, `dot-party`, `dot-friends`, `dot-matchmaking`, `dot-locale`, `dot-moderation`, `dot-settings`, `dot-workbench`.
- **Player and world**: `dot-player`, `dot-player-controller`, `dot-player-char`, `dot-player-class`, `dot-2d`, `dot-physics`, `dot-spawn`, `dot-team`, `dot-entity`, `dot-combat`, `dot-effects`, `dot-weapon`, `dot-loadout`, `dot-inventory`, `dot-economy`, `dot-props`, `dot-vehicle`, `dot-npc`, `dot-npc-ai`, `dot-npc-ai-director`, `dot-bot`, `dot-bot-learn`, `dot-bot-record`, `dot-procedural-generation`, `dot-lighting`, `dot-flashlight`, `dot-weather`, `natural-disasters`.
- **Rules of play**: `dot-match`, `dot-objective`, `dot-vote`, `dot-map`, `dot-timer`, `dot-leaderboard`, `dot-stats`, `dot-achievements`, `dot-replay`, `dot-spectate`.
- **Presentation**: `dot-ui`, `dot-menu`, `dot-console`, `dot-chat`, `dot-voice`, `dot-audio`, `dot-radio`, `dot-fx`.
- **Templates and packs**: `dot-game-template` (what a third-party developer copies), `zee-dot-weapons`, `zed-dot-weapons`, `zz-historical-monsters`, `zz-medieval-weapons`, `zz-modern-weapons`.
- **Games** (`zees-games` org): `game-arena` (the reference), `game-playground`, `game-g2gfast`, `game-hungario`, `game-hide-n-seek`, `game-zombie-zone`, `game-murder-mystery`, `mg-smash-copter`, `mg-buses-from-hell`, `mg-wipeout`, `mg-deathrun`, `mg-dangerous-delivery`, `mg-look-at-me`, `mg-prop-hunt`.
- **Map repos**, each linked into its game: `arena-surf-dm-maps`, `g2gfast-maps`, `game-playground-maps`, `mg-wipeout-maps`, `mg-deathrun-maps`, `mg-prop-hunt-maps`, `hide-n-seek-maps`, `zombie-zone-maps`, `murder-mystery-maps`. `inspirations/` is not a repository.

**Anything every game needs goes in an addon, not in the games.** A loading screen, a settings menu, a scoreboard or a web fix written into one game is missing from the other thirteen; that is how most games went without a loading cover until 2026-10-18. A game's client starts from `DotGameClient` ([dot-game/docs/client-migration.md](godot/dot-game/docs/client-migration.md)); when a game has to work round it, add the hook to dot-game instead.

## Repositories, owners and pushing

**Two owners, and the split is a rule.** Official addons, including `dot-server-deploy`, are the organisation's: `github.com/modcommunity/dot-*`; an addon that is Christian's own (`dot-radio`) lives in `zees-games` and `projects.tsv` says which. Every game, map repo and weapon pack is Christian's, in his `zees-games` organisation: `github.com/zees-games/<dir>` (moved from `gamemann` 2026-10-11; GitHub redirects the old URLs). Their dot-cloud pack ids stay `gamemann/<repo>`, because a pack's owner segment is the site username, not the GitHub owner. `dot-bootstrap/projects.tsv` writes each URL out, and `dot-server-deploy/setup.sh`'s `repo_url()` encodes the same rule for a fresh box. A repository's name is always its directory name.

`godot/push-github.sh` pushes every repository in one pass. It pushes the **current** branch, not `main`, because `git push origin main` from a task branch pushes a stale ref and reports success.

## The documentation

| Read | Before |
| --- | --- |
| [docs/projects.md](docs/projects.md) | Working in a project you have not touched: what it is and what is unusual about it |
| [docs/family.md](docs/family.md) | Touching any addon: what each is responsible for, and the dependency shape |
| [docs/bugs-found.md](docs/bugs-found.md) | Believing a suite. About 150 bugs found by running rather than reading |
| [docs/detectors.md](docs/detectors.md) | A review pass. The greps that have each caught a real bug more than once |
| [docs/gdscript-hazards.md](docs/gdscript-hazards.md) | Writing GDScript. Language and engine traps that do not error usefully |
| [docs/testing.md](docs/testing.md) | Adding a check. Which suites matter, and the two patterns no assertion catches |
| [docs/extension-points.md](docs/extension-points.md) | Adding anything to an addon. The subclass-or-assign table; nothing should need a fork |
| [docs/development-setup.md](docs/development-setup.md) | Cloning, linking, or opening a project standalone |
| [docs/backbone.md](docs/backbone.md) | Anything that talks to website-city |
| [docs/engine.md](docs/engine.md) | Anything version-specific, or a browser-build constraint |
| [docs/status.md](docs/status.md) | Planning. What runs where, and the largest remaining gaps |
| [docs/external-study.md](docs/external-study.md) | Designing something from scratch |
| [PLATFORM.md](PLATFORM.md) | Asking how the set adds up to a platform |

Read each project's own `CLAUDE.md` before working in it.

## Family-wide conventions

Breaking one of these is a breaking change across the whole family.

- **No autoloads, anywhere.** An autoload reserves a global name in every consumer, fixes initialisation order, and cannot be instantiated twice, which rules out a server and a client in one process. Use `DotRegistry` and place nodes yourself. Static classes cannot declare signals, which is why `DotLogBus` and `DotRegistryBus` exist.
- **Nothing hardcodes a scene path.** A component that needs a host node exports a `DotNodeRef` (relative, absolute, self, parent, group, registry, nearest ancestor or descendant of a type, or create if missing).
- **Fallible operations return `DotResult`.** Never null, never an `Array` pair. Branch on `DotError.CODE_*`, never on the message. `res.wrap(...)` adds context and keeps the cause.
- **Ask about capabilities, not platforms**: `DotPlatform.has_threads()`, not `OS.get_name() == "Web"`.
- **Everything is `Dot`-prefixed**, because `class_name` is global (dot-2d uses `Dot2D*`).
- **Configuration is layered** the same everywhere: exported defaults < JSON file < environment < command line. Secrets are refused from environment and argv (`DotConfig.sensitive_keys`).
- **Everything logs through `DotLog`, and the level is a promise.** TRACE per-frame detail; DEBUG a decision or transition; INFO what an admin would keep; WARN recoverable, somebody should look; ERROR the operation failed; **FATAL the process cannot continue** (there is exactly one in the tree). Each logging file declares `const CHANNEL := "…"`; a CHANNEL declared and never used is a file that meant to say something and does not (grep in [docs/detectors.md](docs/detectors.md)).
- **`print` and `push_error` are not logging.** `print` is a program's output (CLI stdout, a console echo). `push_error` is a programmer error that wants the Errors dock. Who acts decides: an operator gets `DotLog`, the person editing the file gets `push_error`. Never `push_warning` for a runtime condition: it staples an unsuppressible backtrace on.
- **`describe()` / `describe_lines()`** on anything with runtime state.
- **Comments explain why, and why the obvious alternative is wrong, in as few lines as it takes** (2026-10-21: 179K of 907K GDScript lines, about a quarter of the bytes, were comments, and every file read pays for them). Do what well-kept open-source projects do: a one-line `##` on each public class, signal and method, a comment where the code cannot say why, nothing that restates the code. A comment is at most three lines; longer reasoning, bug stories, dates, "found by" and "used to" history go in the commit message or `docs/bugs-found.md`, never above the code. No section banners, no commented-out code. When you touch a file, trim the comments in the part you touch to this rule; never reformat a file just to trim it.
- **Markdown is never hard-wrapped**: one paragraph per line, in every `.md` here.
- **Suite results are never written in docs** (2026-11-04). No README, `CLAUDE.md` or `docs/` page states a check count, section count or "N passed": it is stale on the next test change, every read pays for it, and health runs kept spending commits "fixing" it. A doc names its suites and says how to run them; the numbers belong in nightly (dev01 `~/stack/nightly`), where each run is recorded and can be looked back at. A suite's in-code `EXPECTED_CHECKS` and section accounting stay: they are a runtime guard, not documentation. When you touch a doc that states a count, replace it with the suite name. nightly has no per-suite result store yet (only run/agent data and `docs-claims`); building one that every health run and `./game.sh test` posts to is open work, and until it exists a health run reports counts in its handback only.
- **Art comes from Kenney first** (CC0; see the `kenney-assets-cc0` memory), then free MIT, CC0 or public-domain sources found online, with URL, author and licence recorded and credited in the README. Never non-commercial, share-alike, no-derivatives, personal-use or ripped assets. A pack that vendors art must survive pack delivery (see mg-buses-from-hell).
- **No other game or engine is named in anything public**: READMEs, examples, code comments, per-project `CLAUDE.md` and `docs/` are all in public repositories. Describe the genre and the reasoning instead. Protocol and library names stay (A2S, DQP, Recast & Detour), and so do cvar names we have adopted as our own (`mp_forcecamera`, `sv_*`, `mp_*`): a cvar is an interface, not a title. **This file and `game-dev/docs/` are the exception**: they are not in a repository.

## Cross-platform constraints the code encodes

Desktop, mobile and the browser from one codebase; the browser is where the constraints live, and the full table with each consequence is in [docs/engine.md](docs/engine.md#cross-platform-constraints-the-code-encodes). The ones that break a build or lose data when forgotten: never name `ENetMultiplayerPeer` (or any template-optional class) in a script, reach it with `ClassDB.instantiate` and `Object.call`; web builds are clients only; `HTTPRequest`, never `HTTPClient`; no threads unless `DotPlatform.has_threads()`; every write to `user://` calls `DotWeb.sync_filesystem()`; and a mounted resource pack can never be unmounted, so dot-cloud namespaces content by `id/version`.

## Validating anything

Every project has the same two steps, and `dot-ci` runs exactly these on every push and tag:

```bash
cd godot/<project>
# 1. Every script parses. --import registers class_name globals first.
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
# 2. It actually works.
godot --headless --path . res://examples/<the example>.tscn
```

**Every game repository has `./game.sh`** (play, online, server, test, shot); `./game.sh test` is both steps with every suite, a timeout and the stderr check, logs in `.godot/test-logs/`. A change to the script goes into every copy.

- **Read a suite's stderr even when it exits 0**: a script error aborts that test, not the run.
- **Cap every headless run with `timeout`**: a scene whose script fails to parse hangs.
- **Re-run `--import` in every project that links an addon after adding a `class_name` to it.** Each project keeps its own class cache, so a new shared class makes every consumer fail with `Identifier "DotX" not declared` until re-imported. That reads like a broken addon and is a stale cache.
- **Every suite counts sections run to completion and a total number of checks.** A script error aborts a section after it announced itself; dot-settings once reported "0 failed" with eight checks missing.
- **A camera that is not a player's eyes goes through dot-core's `DotCameraProbe`/`DotCameraBoom`, never a bare `SpringArm3D`**, and every game's `tools/camera_check` flies its cameras round its level, armed. The view key is F5 under `mp_forceview`; bodies under `mp_solidplayers` (dot-player-controller).
- **An interface and motion are what no assertion reaches.** Every UI or view change wants a frame rendered and looked at (`tools/screenshot.sh`). Details: [docs/testing.md](docs/testing.md), [docs/bugs-found.md](docs/bugs-found.md), [docs/gdscript-hazards.md](docs/gdscript-hazards.md).

Worktrees go under `~/wt/<repo>-<task>`, never inside `~/godot` (which holds only the `projects.tsv` repositories); `~/wt/prune.sh` removes merged, clean ones.
