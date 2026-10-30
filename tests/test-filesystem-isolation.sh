#!/usr/bin/env bash
# Isolated real-Docker test; never probes or modifies an existing deployment.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec bash tests/run-integration.sh --case filesystem "$@"
