#!/usr/bin/env bash
# Verifies scripts/pentest-task.sh actually terminates a task once it exceeds
# MAX_TASK_RUNTIME, rather than letting it run indefinitely.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

info "This is a manual/integration test outline (requires a real or mocked"
info "openclaw-cli invocation, which needs valid provider credentials to fully"
info "exercise). Steps:"
cat <<'EOF'
  1. Set MAX_TASK_RUNTIME=10s in .env (temporarily).
  2. Run:
       ./scripts/pentest-task.sh --target <a small test repo> \
         --spec <a spec file> --max-runtime 10s
  3. Confirm the wrapper exits within ~10-40s (10s timeout + up to 30s kill-after
     grace period), not indefinitely.
  4. Confirm state/quota-guard/tasks/<task-id>.json has status=LIMIT_REACHED
     and stop_reason=max_runtime_exceeded.
  5. Confirm no openclaw-cli container is still running:
       docker compose -f compose/compose.yml ps openclaw-cli
  6. Restore MAX_TASK_RUNTIME in .env afterwards.
EOF
