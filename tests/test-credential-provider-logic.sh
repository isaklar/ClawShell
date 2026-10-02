#!/usr/bin/env bash
# Unit-tests scripts/lib/common.sh's check_no_placeholder_secrets logic —
# specifically the MODEL_PROVIDER=github-copilot exemption added when this
# repo switched its default provider. Runs entirely with temp files, no
# Docker/root/deployed host required.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAIL=0
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAIL=1; }

# Isolate from the real .env / common.sh's `set -e` so one failing case
# doesn't kill this whole test script.
run_check() {
  local env_content="$1"
  local tmp_env
  tmp_env="$(mktemp)"
  printf '%s\n' "$env_content" > "$tmp_env"
  bash -c '
    set -uo pipefail
    source scripts/lib/common.sh
    ENV_FILE="'"$tmp_env"'"
    check_no_placeholder_secrets
  ' >/tmp/check-out.$$ 2>&1
  local rc=$?
  cat /tmp/check-out.$$ > /tmp/check-out-last.$$
  rm -f /tmp/check-out.$$ "$tmp_env"
  return $rc
}

# 1. github-copilot (default), no API key, no COPILOT_GITHUB_TOKEN, valid
#    GITHUB_AGENT_TOKEN → should PASS (no separate model API key required).
if run_check $'MODEL_PROVIDER=github-copilot\nGITHUB_AGENT_TOKEN=ghp_realtoken\n'; then
  ok "github-copilot + no MODEL_PROVIDER_API_KEY passes (no key required for this provider)"
else
  bad "github-copilot + no MODEL_PROVIDER_API_KEY should pass but failed: $(cat /tmp/check-out-last.$$)"
fi

# 2. github-copilot but GITHUB_AGENT_TOKEN still a placeholder while
#    GITHUB_ALLOWED_REPOS is configured (agents expected to reach GitHub)
#    → should FAIL. Without GITHUB_ALLOWED_REPOS the token is not required,
#    so the scope var must be set for this placeholder check to trigger.
if run_check $'MODEL_PROVIDER=github-copilot\nGITHUB_ALLOWED_REPOS=exampleorg/target-repo\nGITHUB_AGENT_TOKEN=REPLACE_ME\n'; then
  bad "github-copilot + placeholder GITHUB_AGENT_TOKEN should fail but passed"
else
  ok "github-copilot + placeholder GITHUB_AGENT_TOKEN correctly fails"
fi

# 3. anthropic with no MODEL_PROVIDER_API_KEY → should FAIL (key required).
if run_check $'MODEL_PROVIDER=anthropic\nGITHUB_AGENT_TOKEN=ghp_realtoken\n'; then
  bad "anthropic + no MODEL_PROVIDER_API_KEY should fail but passed"
else
  ok "anthropic + no MODEL_PROVIDER_API_KEY correctly fails"
fi

# 4. anthropic with placeholder MODEL_PROVIDER_API_KEY=REPLACE_ME → FAIL.
if run_check $'MODEL_PROVIDER=anthropic\nMODEL_PROVIDER_API_KEY=REPLACE_ME\nGITHUB_AGENT_TOKEN=ghp_realtoken\n'; then
  bad "anthropic + REPLACE_ME MODEL_PROVIDER_API_KEY should fail but passed"
else
  ok "anthropic + REPLACE_ME MODEL_PROVIDER_API_KEY correctly fails"
fi

# 5. anthropic with a real key → should PASS.
if run_check $'MODEL_PROVIDER=anthropic\nMODEL_PROVIDER_API_KEY=sk-ant-real\nGITHUB_AGENT_TOKEN=ghp_realtoken\n'; then
  ok "anthropic + real MODEL_PROVIDER_API_KEY passes"
else
  bad "anthropic + real MODEL_PROVIDER_API_KEY should pass but failed: $(cat /tmp/check-out-last.$$)"
fi

# 6. MODEL_PROVIDER unset entirely → common.sh defaults to github-copilot,
#    should behave like case 1 (PASS with no model key).
if run_check $'GITHUB_AGENT_TOKEN=ghp_realtoken\n'; then
  ok "MODEL_PROVIDER unset defaults to github-copilot behavior (passes without a model key)"
else
  bad "MODEL_PROVIDER unset should default to github-copilot behavior but failed: $(cat /tmp/check-out-last.$$)"
fi

rm -f /tmp/check-out-last.$$

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL CREDENTIAL-LOGIC CHECKS PASSED"
else
  echo "CREDENTIAL-LOGIC CHECKS FAILED — see FAIL lines above"
fi
exit "$FAIL"
