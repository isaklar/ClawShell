#!/usr/bin/env bash
# Requires a Docker Engine/Compose host; creates only an isolated test project.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec python3 tests/integration/run.py "$@"
