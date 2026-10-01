#!/usr/bin/env bash
# Unit-tests quota-guard/addons/quota_guard_addon.py's GITHUB_ALLOWED_REPOS
# enforcement (_extract_github_repo/_allowed_github_repos). Runs entirely
# with temp dirs/env vars, no Docker/root/deployed host required.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAIL=0
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAIL=1; }

OUT="$(mktemp)"
TMPDIR_QG="$(mktemp -d)"
trap 'rm -f "${OUT}"; rm -rf "${TMPDIR_QG}"' EXIT

python3 - "${TMPDIR_QG}" > "${OUT}" 2>&1 <<'PYEOF'
import os, sys

tmp = sys.argv[1]
os.environ["QUOTA_GUARD_STATE_DIR"] = tmp
os.environ["QUOTA_GUARD_LOG_DIR"] = tmp
os.environ["QUOTA_GUARD_ALLOWLIST_DIR"] = tmp
os.environ["QUOTA_GUARD_STATIC_ALLOWLIST"] = os.path.join(tmp, "allowlist.conf")
open(os.environ["QUOTA_GUARD_STATIC_ALLOWLIST"], "w").close()

sys.path.insert(0, "quota-guard/addons")
import quota_guard_addon as qg

checks = []

def check(name, cond):
    checks.append((name, bool(cond)))

# git smart-HTTP clone/fetch/push paths -> matched.
check(
    "github.com clone path matched",
    qg._extract_github_repo("github.com", "/isaklar/clawshell.git/info/refs") == "isaklar/clawshell",
)
check(
    "github.com upload-pack path matched",
    qg._extract_github_repo("github.com", "/isaklar/clawshell.git/git-upload-pack") == "isaklar/clawshell",
)
check(
    "github.com receive-pack (push) path matched",
    qg._extract_github_repo("github.com", "/isaklar/clawshell.git/git-receive-pack") == "isaklar/clawshell",
)

# Non-repo github.com paths must NOT be matched (auth flows must never break).
check(
    "github.com device-login NOT matched (fail open)",
    qg._extract_github_repo("github.com", "/login/device/code") is None,
)
check(
    "github.com oauth token endpoint NOT matched (fail open)",
    qg._extract_github_repo("github.com", "/login/oauth/access_token") is None,
)

# codeload.github.com archive downloads -> matched.
check(
    "codeload.github.com archive path matched",
    qg._extract_github_repo("codeload.github.com", "/isaklar/clawshell/tar.gz/main") == "isaklar/clawshell",
)

# api.github.com repo-scoped REST calls -> matched; non-repo calls -> not.
check(
    "api.github.com repos/ path matched",
    qg._extract_github_repo("api.github.com", "/repos/isaklar/clawshell/pulls") == "isaklar/clawshell",
)
check(
    "api.github.com /user NOT matched (fail open)",
    qg._extract_github_repo("api.github.com", "/user") is None,
)
check(
    "api.github.com /rate_limit NOT matched (fail open)",
    qg._extract_github_repo("api.github.com", "/rate_limit") is None,
)

# _allowed_github_repos(): comma-separated, whitespace-tolerant, lowercased.
os.environ["GITHUB_ALLOWED_REPOS"] = "IsakLar/Agent-Server, someorg/other"
allowed = qg._allowed_github_repos()
check(
    "_allowed_github_repos lowercases + trims + splits",
    allowed == {"isaklar/clawshell", "someorg/other"},
)

os.environ["GITHUB_ALLOWED_REPOS"] = ""
check(
    "_allowed_github_repos empty when unset (unenforced)",
    qg._allowed_github_repos() == set(),
)

for name, passed in checks:
    print(f"{'PASS' if passed else 'FAIL'}\t{name}")

if not all(p for _, p in checks):
    sys.exit(1)
PYEOF
PY_RC=$?

while IFS=$'\t' read -r status name; do
  [[ -z "${status:-}" ]] && continue
  if [[ "${status}" == "PASS" ]]; then
    ok "${name}"
  else
    bad "${name}"
  fi
done < "${OUT}"

if [[ ${PY_RC} -ne 0 && ${FAIL} -eq 0 ]]; then
  bad "python harness exited non-zero unexpectedly: $(cat "${OUT}")"
fi

if [[ "${FAIL}" -eq 0 ]]; then
  echo
  echo "ALL GITHUB REPO-SCOPE CHECKS PASSED"
  exit 0
else
  echo
  echo "GITHUB REPO-SCOPE CHECKS FAILED"
  exit 1
fi
