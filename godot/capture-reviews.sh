#!/usr/bin/env bash
# capture-reviews.sh <game> [--all|--dry-run|--no-post] [item...]: animation clips to the nightly /reviews page.
g=${1:?usage: capture-reviews.sh <game> [item...]}; shift
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/$g" && exec bash tools/capture_reviews.sh "$@"
