#!/usr/bin/env bash
exec "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/dot-bootstrap/tools/gpu.sh" "$@"
