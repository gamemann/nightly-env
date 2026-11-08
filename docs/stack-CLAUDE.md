# ~/stack — workspace rules for every session

Each repository has its own `CLAUDE.md`; read it too. This file only covers working
alongside other Claude sessions.

## Agent board — check it before editing

Other Claude sessions (the scheduled runs, other live sessions) may be working in `~/stack`
at the same time. The board (`~/stack/nightly/bin/nightly agent …`, the Agents tab in the
nightly panel on :3010) keeps two of them out of the same repository:

```
N=~/stack/nightly/bin/nightly
$N agent join <short-name> --task "<what you are doing>"   # once, at the start; prints who else is live
$N agent claim <short-name> <repo>[/<path>]                 # before changing files; exit 3 = held by a live agent
$N agent say <short-name> [--to NAME] "..."                 # ask for a hand-over, warn about a shared file
$N agent inbox <short-name>                                 # now and then, and when a command says you have mail
$N agent release <short-name> <repo>                        # when your commit is in
$N agent leave <short-name>                                 # when you are done
```

- Pick a short name for the session (e.g. the repo and the task: `city-header`) and use it on every call.
- Claim before your first edit; read-only work needs no claim. **Claim the files or
  directory you will change, not the whole repo** (`website-city/src/app/_components/ui/form/x.tsx`).
  A repo-wide claim blocks everyone else for one file's work.
- **Only a refusal of the path you are editing stops you.** If others hold paths in the repo but not yours,
  claim your file and carry on. If the board says the holder is stale ("not blocking"),
  claim and carry on. Do not stop to ask Christian in either case.
- A refused claim means another live session is changing that path: do not edit it.
  Message the holder, and tell the user who holds it and what they are doing.
  Do not use `--force` unless the user says to.
- Paths are relative to `~/stack` (`website-city`, `nightly`); work on x-tmc-dev02 is claimed as `dev02:<path under ~ there>` (`dev02:godot/dot-map`); a claim on a
  repository covers everything inside it.

## Spawning agents: pick the cheapest model that can do it

Usage is mostly context re-read on every call, so agent size and model are the cost. Use the typed agents in `~/.claude/agents/`, never a bare general-purpose spawn (a hook refuses one without `model`): **`scout`** (haiku) for read-only lookups, **`researcher`** (sonnet) for web research, **`builder`** (sonnet) for one scoped change in **one** repo, **`specialist`** (opus) only for hard cross-repo problems or after a builder failed. Work across several repos is one builder per repo. Ask agents for short reports and keep build and test logs out of context (tail/grep them). Start a fresh orchestrator session per batch of work instead of one that runs for days; the board and git hold the state. Before calling a large change (or one in a shared addon, auth or security) done, have a fresh agent that did not write it review the diff against the task and report correctness gaps only; a reviewer asked for gaps always finds some, so skip the style ones.

**When compacting**, keep the repos claimed on the board, every commit made (repo and hash) and whether it is pushed, the branch each repo is on, and the exact checks still to run.

**The orchestrator itself runs on Sonnet for routine batches**: handing known tasks to builders, reading their reports, re-spawning a failed one, keeping the board current. Start those sessions with `claude --model sonnet` (or `/model sonnet`). Use Opus for the session when the batch is design, cross-addon planning, or triage of a bug nobody understands yet, and switch with `/model` mid-session when a routine batch turns into one of those. The orchestrator was about a quarter of all usage when it always ran on Opus. **The nightly runner is the same split, fixed in place**: its coordinator runs on Sonnet (`run.sh`, `NIGHTLY_MODEL`) and spawns its builders with `model: "opus"` (`nightly.md`, "Sub-agents"), while interactive sessions keep Opus as the default.

## Memory: builds and suites go through `heavy`

Both VMs ran out of RAM when parallel agents built and tested at the same time, and the host killed x-tmc-dev01 (2026-10-16). Every build, smoke/verify run, Playwright run, type-check, cargo build and Godot run goes through **`heavy -- <command>`** on the VM that runs it. A Bash hook refuses the bare command and prints the rewrite. `heavy` queues jobs per VM (one build or suite, two checks) and waits for free memory. Put long runs in `run_in_background`; `heavy --status` shows the queue. Run **at most three sub-agents at a time, and at most two of them builders** (or anything else that runs suites): `heavy` runs one build or suite per VM, so a third builder mostly waits in the queue while its 5-minute prompt cache expires and must be re-written. Everything the `christian` user runs is also capped (`user-1000.slice` MemoryMax), so a job that overshoots kills itself, not the VM. Details: `~/stack/nightly/scripts/heavy/README.md` on x-tmc-dev01.

## Finishing a task: nothing narrowed in silence

- **Only Christian makes part of his request optional.** If something he asked for is not done, or was done differently (a repo left on the old way, a game skipped, a feature cut), it goes in the final report under a **Not done / exceptions** heading, each with the reason. "Every game" means every game unless the report says otherwise.
- **A gap is written down as unfinished work, never as a fact.** Not "every game but X uses Y", but "X is not converted yet, because …", plus a nightly queue item (`$N add …`) to finish it. Docs that state an exception as design make the next agent preserve it.
- **Before calling a task done, check it against the request, not against your own plan.** Re-read his words. If a context summary is all you have of them, `nightly show <key>` or the transcript is the source.

## Documentation: CLAUDE.md is the current state, history goes elsewhere

Every repository follows website-city's layout:

- **`CLAUDE.md`, at most ~15 KB**: what the repo is, its layout, how to run and test it, the rules and traps that apply NOW (one line each, pointing at the reasoning), and a "Read X before Y" table into `docs/`.
- **`docs/<topic>.md`**: design reasoning that still describes the code, one subject per file, with `docs/README.md` as the index once there are more than three.
- **`docs/history.md`**: bug stories and dated decisions worth keeping. A story whose lesson still applies also leaves a one-line rule in `CLAUDE.md` or the topic doc.
- **Never written into any of them**: release logs, "committed / pushed / tagged on <date>" status, and progress reports. Git and the nightly queue hold those. Put them in the final report instead.

When you learn something while working, add the rule where it applies, in one line, and the story to `docs/history.md` only if the bug could come back. Do not append a dated section to `CLAUDE.md`.

## Game development moved to x-tmc-dev02

Since 2026-10-14, TMC game development (the Godot tree, `dot-*` addons, games, map repos, `docs/`) lives on **`x-tmc-dev02`**, in `~/godot` and `~/docs` there. `~/stack/game-dev` on this machine is gone; never recreate it. This VM (`x-tmc-dev01`) stays the app and web VM, and the game VM uses this one's website-city, PostgreSQL, Redis and nginx (`tmcdev.net`) rather than running its own.

**You have full access to x-tmc-dev02**: `ssh -i ~/.ssh/dev02 x-tmc-dev02` (user `christian`, `x-tmc-dev02.deacon.internal`, 10.50.0.164). Read, edit, run Godot suites, commit and push there as you would here. Claude Code is installed there (`~/.local/bin/claude`); its own `~/CLAUDE.md` is the game tree's rules, read it before game work. Passwordless `sudo` works there (since 2026-10-14).

**x-tmc-dev02 has full access back to this VM** (`ssh -i ~/.ssh/dev01 x-tmc-dev01` from there), and Claude sessions there are expected to read, edit and run things in `~/stack`, start dev servers, and tunnel to PostgreSQL/Redis. Do not treat a dev02 session's work here as foreign.

**Sessions on the two VMs coordinate through this board.** A dev02 session runs `~/stack/nightly/bin/nightly agent …` over SSH, with the same rules: join, claim before editing (a `~/stack` repo, or `dev02:<path>` for its own tree), `say` and `inbox` to hand over or warn, release, leave. If you need something done on dev02 while a session is live there, message it on the board rather than editing under it.
