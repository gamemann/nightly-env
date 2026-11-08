# godot

Godot 4 assets. Each subdirectory is a separate asset/project.

- **Each subdirectory is its own Git repository and is cloned individually.**
  Neither this directory nor `~/` (the game-dev tree) is a repository, so there is no way to clone
  the whole tree at once.
- Requires Godot 4.7 or newer.
- Every addon's distributable is its `addons/<name>/` folder. Everything outside
  that — `project.godot`, `examples/` — exists so the addon can be opened and
  validated standalone and is not copied into consuming projects.
- `dot-serve` is not a Godot project. It is a shell launcher.
- `game-*` are games rather than addons: they ship no `addons/<name>/` of their own and
  exist to be played, and to be the only place the addons are exercised together.

## What each project is

Not listed here, because a list in this file drifted (it once had four of the thirteen games). The one list of projects is `dot-bootstrap/projects.tsv`; what each is responsible for and how they depend on each other is [../docs/family.md](../docs/family.md); a paragraph per project, including games, map repos and weapon packs, is [../docs/projects.md](../docs/projects.md).

`dot-map-convert` is the one repository here that is not a Godot project: the BSP converter and its replacement tables, plain Python. Games and map repos find it as a sibling checkout (`DOTBSP_PATH` overrides).

## Pushing

`./push-github.sh` pushes every repository here in one pass, and
`./push-github.sh --dry-run` says what it would do without touching anything.

It pushes the **current** branch rather than `main`, because several of these sit on
a task branch and `git push origin main` from one of those pushes the local `main`
ref — which is behind the work, so the command succeeds and nothing anybody wrote
goes anywhere. It also pushes `main` as well when the current branch is not `main`,
and reports a repository with no remote rather than stopping on it.

## Coupling

**Only dot-core is ever a hard dependency.** Everything else is discovered at runtime,
duck-typed, or bridged by the host — and in GDScript that is not merely a preference: a
script that *mentions* a `class_name` the project does not have fails to parse, and
takes every script that references it down with it.

- dot-server discovers dot-auth and dot-cloud through `DotRegistry` and imports neither.
- dot-net needs only dot-core and moves bytes through a `Callable`.
- dot-player-controller, dot-combat, dot-loadout, dot-match and dot-2d each ship a
  `*NetSync` class that describes what to replicate as **data** — property names and
  type names as *strings* — which a bridge resolves with `DotNetVar.Type[spec.type]`.
  None of them names a dot-net identifier.
- dot-combat takes lag compensation as two `Callable`s and movement state as pushed
  fields.
- dot-ui names nothing outside dot-core: its feed takes coloured fragments and its
  table takes rows of dictionaries.
- `dot-user` and `dot-user-avatar` do not import each other, and `dot-loadout` carries
  its own copy of the storage-key check for the same reason. **Do not deduplicate
  those.**

The bridges those refusals imply live in the games. `game-arena` and `game-hungario`
are where they are written, and where they are run.

## Local development, checks, conventions

Linking addons into a project is `dot-bootstrap`'s job, never done by hand: see [../docs/development-setup.md](../docs/development-setup.md). Every repository runs the same two-step check (every script parses, then every headless suite runs) locally and, on every push and `v*` tag, through [dot-ci](dot-ci), which signs nothing and needs no secret while the repositories are public. The family-wide rules are in [../CLAUDE.md](../CLAUDE.md), and the platform these add up to is described in [../PLATFORM.md](../PLATFORM.md).

Git worktrees never go inside `~/godot`: make them under `~/wt/<repo>-<task>` (`git -C ~/godot/<repo> worktree add ~/wt/<repo>-<task> -b <branch>`), remove them with `git worktree remove` once merged, and run `~/wt/prune.sh` to drop every merged, clean one; scratch files go in `~/scratch-archive/` or the scratchpad, never in `~/godot`, which holds only the repositories in `dot-bootstrap/projects.tsv` plus a few top-level scripts.
