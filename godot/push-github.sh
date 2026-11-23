#!/usr/bin/env bash
#
# push-github.sh — push every gs-* / game-* repository under this directory.
#
# Each subdirectory of godot/ is its own Git repository (see ../CLAUDE.md), so
# "push the work" is one push per directory — fifty-eight of them as this is written,
# and the count is never hardcoded anywhere here: this walks the disk, so a repository
# added or renamed today is pushed today. It does them in one pass and prints one line
# per repository saying what happened.
#
# It is deliberately DUMB about credentials: it runs `git push` and lets your
# existing SSH agent or credential helper answer. Nothing here reads a token.
#
# Three things it does that a bare `git push origin main` loop does not, each
# because the bare loop gets it wrong here:
#
#  1. It pushes the CURRENT branch, not `main`. Several of these repositories sit
#     on a task branch, and `git push origin main` from one of them pushes the
#     local `main` ref — which is behind the work that was actually done, so the
#     command succeeds and nothing anybody wrote goes anywhere.
#  2. It pushes `main` as well when the current branch is something else, so a
#     repository that has both still gets both.
#  3. It says when a repository has no remote rather than failing. The newest
#     addons have not been created on GitHub yet, and a script that stopped on
#     the first of them would never reach the ones that have.
#
# Usage:
#   ./push-github.sh              # push everything
#   ./push-github.sh --dry-run    # say what it would push, touch nothing
#   ./push-github.sh --force      # push a REWRITTEN history (see below)
#   ./push-github.sh --no-parse   # skip the parse gate (see below)
#   ./push-github.sh gs-timer …  # only these
#
# --force is for the one case an ordinary push cannot serve: history that has been
# rewritten locally, where the remote's commits are no longer an ancestor of yours
# and every push is refused as a non-fast-forward. It uses --force-with-lease, which
# refuses when the remote has moved since you last fetched it — so it overwrites your
# own rewritten history and never somebody else's work you have not seen. It is an
# explicit flag rather than a fallback because a push that quietly forces is a push
# that quietly discards.
#
#
# Parse gate: before pushing a repository that has a project.godot, every .gd file
# changed since origin/<branch> must pass `--check-only` (after an `--import`, so class_name
# globals resolve), run through `heavy`. A repository that fails is not pushed. Merged
# agent commits broke the parse on main twice; this is what stops a third.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# Repositories this never pushes, whatever is asked of it.
#
# Not a filter on what is interesting: it is a filter on what is meant to be public.
# A repository that exists to try something out has no reason to be on GitHub, and a
# push script that publishes everything it finds is one nobody can leave running
# unattended. Naming one on the command line does not override this — an override is
# the thing that gets typed by accident.
#
# It is EMPTY, and the entry it used to hold is the reason the comment above is worth
# keeping. `gs-server-setup-test` was excluded as a throwaway experiment that had no
# GitHub repository; it is the deployment tool, it has had one for months, and the
# exclusion outlived the reason for it — so the one repository an operator most needs
# published was the one this script quietly skipped, in a line that reads as a
# decision somebody made on purpose. An exclusion is a claim about today, and this one
# also went stale by NAME: the directory is `gs-server-deploy` now, so the entry had
# stopped matching anything at all and was excluding nothing.
NEVER_PUSH=()

DRY_RUN=0
FORCE=0
PARSE=1
SELECTED=()

for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        --force|-f) FORCE=1 ;;
        --no-parse) PARSE=0 ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            echo "unknown option: $arg" >&2
            exit 2
            ;;
        *) SELECTED+=("$arg") ;;
    esac
done

# Colours only when stdout is a terminal: this gets piped into logs.
if [ -t 1 ]; then
    OK=$'\033[32m'; WARN=$'\033[33m'; ERR=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
    OK=''; WARN=''; ERR=''; DIM=''; OFF=''
fi

pushed=0
skipped=0
failed=0
dirty=0

say() { printf '%-26s %s\n' "$1" "$2"; }

# Prints the unparseable files of repo $1, nothing if all parse or there is nothing to check.
parse_failures() {
    local name="$1" branch="$2" files f
    [ -f "$name/project.godot" ] || return 0
    git -C "$name" rev-parse --verify --quiet "origin/$branch" >/dev/null || return 0
    files="$(git -C "$name" diff --name-only --diff-filter=AM "origin/$branch..HEAD" -- '*.gd')"
    [ -n "$files" ] || return 0
    # An unfinished import leaves class_name globals unresolved, which fails every
    # --check-only that uses them; so a failed import is its own error, not parse errors.
    import_ok() { heavy -- timeout 300 godot --headless --path "$name" --import >/dev/null 2>&1; }
    if ! import_ok; then
        echo "IMPORT FAILED (godot --import timed out or errored; not a parse error)"
        return 0
    fi
    while IFS= read -r f; do
        [ -f "$name/$f" ] || continue
        check() { heavy -- timeout 60 godot --headless --path "$name" --check-only --script "res://$f" >/dev/null 2>&1; }
        check && continue
        import_ok && check || echo "$f"
    done <<< "$files"
}

for dir in */; do
    name="${dir%/}"

    [ -d "$name/.git" ] || continue

    # `${NEVER_PUSH[@]+...}` because the list is empty and `set -u` is on: an
    # unadorned expansion of an empty array is an unbound variable on the bash
    # this has to keep working under.
    excluded=0
    for never in ${NEVER_PUSH[@]+"${NEVER_PUSH[@]}"}; do
        [ "$never" = "$name" ] && excluded=1
    done

    if [ $excluded -eq 1 ]; then
        say "$name" "${DIM}excluded — see NEVER_PUSH in this script${OFF}"
        skipped=$((skipped + 1))
        continue
    fi

    if [ ${#SELECTED[@]} -gt 0 ]; then
        found=0
        for want in "${SELECTED[@]}"; do
            [ "$want" = "$name" ] && found=1
        done
        [ $found -eq 1 ] || continue
    fi

    remote="$(git -C "$name" remote get-url origin 2>/dev/null)"

    if [ -z "$remote" ]; then
        say "$name" "${WARN}no origin remote — create it on GitHub first${OFF}"
        skipped=$((skipped + 1))
        continue
    fi

    branch="$(git -C "$name" rev-parse --abbrev-ref HEAD 2>/dev/null)"

    if [ "$branch" = "HEAD" ]; then
        say "$name" "${WARN}detached HEAD — check it out on a branch first${OFF}"
        skipped=$((skipped + 1))
        continue
    fi

    # Reported, never acted on. Committing on somebody's behalf from a push
    # script is how a half-finished change reaches a remote.
    changes="$(git -C "$name" status --porcelain | wc -l | tr -d ' ')"
    # Untracked files do not block a rebase or fast-forward; tracked edits do.
    tracked="$(git -C "$name" status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
    note=""

    if [ "$changes" != "0" ]; then
        note=" ${WARN}(${changes} uncommitted, not pushed)${OFF}"
        dirty=$((dirty + 1))
    fi

    # The current branch, then main if that was something else. `git push origin
    # main` alone would push a stale ref from a repository on a task branch.
    refs=("$branch")

    if [ "$branch" != "main" ] && git -C "$name" show-ref --verify --quiet refs/heads/main; then
        refs+=("main")
    fi

    # --force-with-lease rather than --force: it refuses if the remote has moved
    # since this clone last saw it, so a rewritten history overwrites the history it
    # was rewritten from and not a colleague's push nobody has fetched.
    push_args=()
    [ $FORCE -eq 1 ] && push_args+=("--force-with-lease")

    if [ $DRY_RUN -eq 1 ]; then
        forced=""
        [ $FORCE -eq 1 ] && forced=" ${WARN}(forced)${OFF}"
        say "$name" "${DIM}would push ${refs[*]} -> ${remote}${OFF}${forced}${note}"
        continue
    fi

    if [ $PARSE -eq 1 ]; then
        bad="$(parse_failures "$name" "$branch")"
        if [ -n "$bad" ]; then
            case "$bad" in
                "IMPORT FAILED"*) say "$name" "${ERR}import failed, not pushed${OFF}" ;;
                *) say "$name" "${ERR}parse gate failed, not pushed${OFF}" ;;
            esac
            printf '%s\n' "$bad" | sed 's/^/    /'
            failed=$((failed + 1))
            continue
        fi
    fi

    ok=1
    output=""

    git -C "$name" fetch origin --quiet 2>/dev/null
    for ref in "${refs[@]}"; do
        # Local is behind or level with the remote: nothing to push. Catch the local ref up
        # when that is safe, and never call it a failure.
        if git -C "$name" rev-parse --verify --quiet "origin/$ref" >/dev/null \
            && git -C "$name" merge-base --is-ancestor "$ref" "origin/$ref"; then
            if [ "$(git -C "$name" rev-parse "$ref")" != "$(git -C "$name" rev-parse "origin/$ref")" ]; then
                if [ "$ref" = "$branch" ]; then
                    [ "$tracked" = "0" ] && git -C "$name" merge --ff-only "origin/$ref" >/dev/null 2>&1
                else
                    git -C "$name" fetch origin "$ref:$ref" --quiet 2>/dev/null
                fi
                note="${note} ${DIM}(${ref} was behind origin, nothing to push)${OFF}"
            fi
            continue
        fi
        output="$(git -C "$name" push "${push_args[@]}" origin "$ref" 2>&1)"
        rc=$?
        # Rejected because the remote moved: rebase our commits on it and retry once. Only
        # for the checked-out branch (a rebase needs it), only on a clean tree, and a
        # conflict aborts the rebase and reports rather than forcing anything.
        if [ $rc -ne 0 ] && [ $FORCE -eq 0 ] && [ "$ref" = "$branch" ] \
            && printf '%s' "$output" | grep -qE 'non-fast-forward|fetch first|behind'; then
            if [ "$tracked" = "0" ] && git -C "$name" pull --rebase origin "$ref" >/dev/null 2>&1; then
                output="$(git -C "$name" push origin "$ref" 2>&1)"
                rc=$?
                [ $rc -eq 0 ] && note="${note} ${DIM}(rebased onto origin)${OFF}"
            else
                git -C "$name" rebase --abort >/dev/null 2>&1
                output="${output}"$'\n'"could not rebase automatically (conflict, tracked edits, or diverged non-checked-out branch); resolve by hand"
            fi
        fi
        if [ $rc -ne 0 ]; then
            ok=0
            say "$name" "${ERR}push ${ref} failed${OFF}"
            printf '%s\n' "$output" | sed 's/^/    /'
        fi
    done

    if [ $ok -eq 1 ]; then
        forced=""
        [ $FORCE -eq 1 ] && forced=" ${WARN}(forced)${OFF}"
        say "$name" "${OK}pushed ${refs[*]}${OFF}${forced}${note}"
        pushed=$((pushed + 1))
    else
        failed=$((failed + 1))
    fi
done

echo
if [ $DRY_RUN -eq 1 ]; then
    echo "dry run — nothing was pushed"
else
    printf '%d pushed, %d skipped, %d failed' "$pushed" "$skipped" "$failed"
    [ $dirty -gt 0 ] && printf ', %d with uncommitted changes' "$dirty"
    echo
fi

# Non-zero only on a real failure. A repository with no remote is a repository
# that has not been created yet, which is a state this script expects.
[ $failed -eq 0 ]
