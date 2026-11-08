#!/usr/bin/env bash
# Site-chrome check. tmc-global's shared/src/data/site-nav.json is the hand-edited
# source of every site's header, rail and footer; this validates it and its consumers.
#
#   check-layout-sync.sh            check; exit 0 OK, 1 problems (listed on stdout), 2 error
#   check-layout-sync.sh --write    format site-nav.json in place (4-space JSON), then check
#   check-layout-sync.sh --quiet    no output when OK
#
# Checks: (1) the JSON: known fields, hrefs, icons NAV_ICONS has, roles/exact/modal
# placement, unique entry paths, socials, copyright with {year} and the legal entity,
# formatting. (2) every site's catalogue, in every locale, has a string for every key
# that site draws (city all; learn and processing skip role-gated entries; status also
# the signed-in ones; the Astro sites through ShellCatalogKey). (3) every buildChrome
# call passes its own `site` and no overrides, no site keeps a nav list of its own, and
# SITE_CHROME_OVERRIDES has no unmatched entries. (4) city's lib/site/links.ts agrees
# with the JSON's socials and off-site URLs, and its NavModalKind has every `modal` kind.
#
# Any repo can be a worktree elsewhere (e.g. another branch):
#   LAYOUT_SYNC_CITY= LAYOUT_SYNC_PROCESSING= LAYOUT_SYNC_LEARN= LAYOUT_SYNC_STATUS= LAYOUT_SYNC_TMC_GLOBAL=
#
# Needs only node >= 22.13 (built-in TypeScript stripping). Runnable from any cwd;
# STACK defaults to this script's parent directory.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_NO_WARNINGS=1 exec node "$here/check-layout-sync.mjs" "$@"
