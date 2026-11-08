# Recovery (rebuild dev from GitHub)

This repo is meant to be public-safe: scripts and manifests only, no secrets.

1. New box: create users `core` and `gamedev` (gamedev with docker group; christian has NOPASSWD sudo to both), install git, docker, godot, node, sqlite3, postgres/clickhouse/redis clients.
2. Give each user a GitHub SSH key (deploy/personal), then as `core`: `git clone git@github.com:gamemann/nightly-env.git /home/core/projects/nightly-env`.
3. `sudo -u core .../restore.sh core` and `sudo -u gamedev .../restore.sh gamedev` clone every repo from `manifest-repos.tsv` and link the scripts. Then `sudo install -m755 bin/heavy /usr/local/bin/heavy`, review and apply `cron/*.crontab`, `systemctl --user enable --now` the units in `systemd/`.
4. Restore the private files listed in `manifest-private-files.tsv` (env files, keys, the nightly database, agent memory) from your private backup. They are NOT in GitHub. Reseed dev databases with each repo's own seed command (`prisma db push`, `db:idx:sync`, seed scripts; see `stack-CLAUDE.md`).
5. Large data not in git must also be backed up elsewhere: BSP sources (`/home/gamedev/projects/mapsrc`, ~32 GB, and `godot/inspirations`).
