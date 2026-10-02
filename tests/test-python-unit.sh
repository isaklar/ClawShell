#!/usr/bin/env bash
# Runs the Python unit suite for the black-box live-testing components
# (target-gateway addon + control API, pentest-tools MCP server). Pure unit
# tests: mitmproxy/mcp are stubbed, DNS and HTTP are faked, and all state is
# redirected to temp dirs — no Docker, no network, no deployed host required.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP python3 not available — skipping Python unit tests"
  exit 0
fi

python3 -m unittest discover -s tests/unit -p 'test_*.py' -v
