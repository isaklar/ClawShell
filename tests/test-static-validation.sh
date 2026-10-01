#!/usr/bin/env bash
# Static regression checks that run on ANY machine with this repo cloned —
# no deployed host, root, or running containers required. Designed to
# catch the class of bug that slips in during doc/script edits: syntax
# errors, drifted phase numbering, gitignore holes, inconsistent allowlist
# defaults, and undocumented env vars. Safe to run in CI or on a dev laptop.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAIL=0
ok()   { printf '  OK   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; }

echo "== Shell syntax =="
while IFS= read -r -d '' f; do
  if bash -n "$f" 2>/tmp/syntax-err.$$; then
    ok "$f"
  else
    bad "$f: $(cat /tmp/syntax-err.$$)"
  fi
  rm -f /tmp/syntax-err.$$
done < <(find scripts caveman-proxy tests -name '*.sh' -print0 2>/dev/null)

echo "== install.sh phase numbering (sequential, no gaps/dupes, total matches) =="
phases=()
while IFS= read -r line; do
  phases+=("$line")
done < <(grep -oE 'Phase [0-9]+/[0-9]+' scripts/install.sh)
if [[ "${#phases[@]}" -eq 0 ]]; then
  bad "no 'Phase N/M' markers found in scripts/install.sh"
else
  total="${phases[0]##*/}"
  expected=1
  numbering_ok=1
  for p in "${phases[@]}"; do
    n="${p#Phase }"; n="${n%%/*}"
    m="${p##*/}"
    if [[ "$m" != "$total" ]]; then
      bad "phase '$p' has inconsistent total (expected /$total)"
      numbering_ok=0
    fi
    if [[ "$n" -ne "$expected" ]]; then
      bad "phase numbering out of sequence: expected Phase ${expected}/${total}, got '$p'"
      numbering_ok=0
    fi
    expected=$((expected + 1))
  done
  if [[ "$((expected - 1))" -ne "$total" ]]; then
    bad "declared total /${total} does not match actual phase count $((expected - 1))"
    numbering_ok=0
  fi
  [[ "$numbering_ok" -eq 1 ]] && ok "phases 1..${total} sequential, no gaps/dupes"
fi

echo "== .env.example vars are all referenced somewhere (catches dead/renamed vars) =="
while IFS= read -r var; do
  [[ -z "$var" ]] && continue
  if grep -rq --include='*.sh' --include='*.yml' --include='*.template' --include='*.json5' \
       -e "\\\$${var}\\b" -e "\\\${${var}" -e "\\\${${var}:" \
       scripts compose firewall config systemd 2>/dev/null; then
    ok "\$${var} referenced"
  else
    bad "\$${var} declared in .env.example but not referenced anywhere under scripts/compose/firewall/config/systemd"
  fi
done < <(grep -oE '^[A-Z_][A-Z0-9_]*=' .env.example | sed 's/=$//')

echo "== allowlist.conf: always-on GitHub hosts present; model-provider hosts consistent with MODEL_PROVIDER =="
if grep -qx 'github.com:443' config/allowlist.conf && grep -qx 'api.github.com:443' config/allowlist.conf; then
  ok "github.com / api.github.com present (uncommented)"
else
  bad "github.com:443 and/or api.github.com:443 missing/commented in config/allowlist.conf"
fi
default_provider="$(grep -oE '^MODEL_PROVIDER=.*' .env.example | tail -1 | cut -d= -f2)"
active_provider_lines="$(grep -cxE '(\*\.githubcopilot\.com|api\.anthropic\.com|api\.openai\.com):443' config/allowlist.conf)"
if [[ "$default_provider" == "local-gpu" ]]; then
  # Local GPU inference needs NO external provider host — expect exactly zero.
  if [[ "$active_provider_lines" -eq 0 ]]; then
    ok "MODEL_PROVIDER=local-gpu: zero external model-provider hosts active (on-box inference)"
  else
    bad "MODEL_PROVIDER=local-gpu but ${active_provider_lines} external model-provider host(s) are active in config/allowlist.conf"
  fi
else
  if [[ "$active_provider_lines" -eq 1 ]]; then
    ok "exactly one model-provider host is active: $(grep -xE '(\*\.githubcopilot\.com|api\.anthropic\.com|api\.openai\.com):443' config/allowlist.conf)"
  else
    bad "expected exactly one active model-provider host in config/allowlist.conf, found ${active_provider_lines}"
  fi
fi

echo "== .env.example default MODEL_PROVIDER matches the active allowlist host =="
case "$default_provider" in
  local-gpu)      expected_host='' ;;
  github-copilot) expected_host='*.githubcopilot.com:443' ;;
  anthropic)      expected_host='api.anthropic.com:443' ;;
  openai)         expected_host='api.openai.com:443' ;;
  *)              expected_host='MISSING' ;;
esac
if [[ "$default_provider" == "local-gpu" ]]; then
  ok "MODEL_PROVIDER=local-gpu needs no external allowlist host (inference is on-box)"
elif [[ "$expected_host" != "MISSING" ]] && [[ -n "$expected_host" ]] && grep -qxF "$expected_host" config/allowlist.conf; then
  ok "MODEL_PROVIDER=${default_provider} matches active allowlist entry ${expected_host}"
else
  bad "MODEL_PROVIDER=${default_provider} in .env.example has no matching active line in config/allowlist.conf"
fi

echo "== Secrets hygiene: nothing under .gitignore'd paths is actually tracked =="
for pattern in '.env$' '^secrets/' '^state/' '^workspaces/' '^logs/' '^backups/' 'config/openclaw\.json5$' 'config/allowlist\.d/.*\.conf$'; do
  hit="$(git ls-files | grep -E "$pattern" || true)"
  if [[ -z "$hit" ]]; then
    ok "no tracked files match ${pattern}"
  else
    bad "tracked file(s) match secret/state pattern ${pattern}: ${hit}"
  fi
done

echo "== Self-documentation: allowlist.d/README.md and .gitkeep are tracked =="
for f in config/allowlist.d/README.md config/allowlist.d/.gitkeep; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    ok "$f is tracked"
  else
    bad "$f exists but is NOT tracked by git (a fresh clone would be missing it)"
  fi
done

echo "== docker compose config validates with placeholder secrets =="
if command -v docker >/dev/null 2>&1; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  mkdir -p "${tmpdir}/secrets" "${tmpdir}/state/openclaw" "${tmpdir}/state/quota-guard" \
           "${tmpdir}/state/sandbox-dind" "${tmpdir}/state/caveman" "${tmpdir}/workspaces" \
           "${tmpdir}/logs/quota-guard" "${tmpdir}/backups"
  for s in gateway_token model_provider_api_key github_agent_token; do
    printf 'placeholder' > "${tmpdir}/secrets/${s}"
  done
  ln -sfn "${tmpdir}/secrets" secrets
  ln -sfn "${tmpdir}/state" state
  ln -sfn "${tmpdir}/workspaces" workspaces
  ln -sfn "${tmpdir}/logs" logs
  ln -sfn "${tmpdir}/backups" backups
  if (cd compose && MODEL_PROVIDER_API_KEY=placeholder docker compose config >/dev/null 2>/tmp/compose-err.$$); then
    ok "docker compose config validates"
  else
    bad "docker compose config failed: $(cat /tmp/compose-err.$$)"
  fi
  rm -f /tmp/compose-err.$$
  rm -f secrets state workspaces logs backups
  trap - EXIT
  rm -rf "${tmpdir}"
else
  echo "  SKIP docker not available on this machine"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL STATIC CHECKS PASSED"
else
  echo "STATIC CHECKS FAILED — see FAIL lines above"
fi
exit "$FAIL"
