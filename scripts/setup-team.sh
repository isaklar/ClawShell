#!/usr/bin/env bash
# Idempotent, safe-to-re-run: seeds AGENTS.md for the 4-agent team
# (main=researcher/architect, recon, exploit, reporter) into their
# per-agent workspaces on the host. Run once after ./install.sh (or after
# ./update.sh, if you add/reset a role), then restart the Gateway so it picks
# up config/openclaw.json5's agents.entries.
#
# Never overwrites a workspace file that already exists — if you've since
# customized an agent's AGENTS.md by hand (or through a live chat session),
# this script leaves it untouched. See docs/pentest-team.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh
load_env

WORKSPACES_ROOT="/opt/clawshell/workspaces"
ROLES_SRC="config/agent-workspaces"

[[ -d "${WORKSPACES_ROOT}" ]] || die "${WORKSPACES_ROOT} does not exist — run ./scripts/install.sh first."

if [[ ! -f "config/openclaw.json5" ]]; then
  warn "config/openclaw.json5 not found. Copy config/openclaw.json5.example to config/openclaw.json5 first (it already defines the 4-agent team) and re-run this script."
  exit 1
fi

seeded=0
skipped=0
for role_dir in "${ROLES_SRC}"/*/; do
  role="$(basename "${role_dir}")"
  # main's workspace is the shared workspace root; every other role gets its
  # own subdirectory, matching agents.entries.*.workspace in
  # config/openclaw.json5.example.
  if [[ "${role}" == "main" ]]; then
    dest_dir="${WORKSPACES_ROOT}"
  else
    dest_dir="${WORKSPACES_ROOT}/${role}"
  fi
  mkdir -p "${dest_dir}"
  chown clawshell:clawshell "${dest_dir}" 2>/dev/null || true

  for f in "${role_dir}"*; do
    fname="$(basename "${f}")"
    dest_file="${dest_dir}/${fname}"
    if [[ -f "${dest_file}" ]]; then
      info "Skipping ${dest_file} (already exists — not overwriting)."
      skipped=$((skipped + 1))
      continue
    fi
    cp "${f}" "${dest_file}"
    chown clawshell:clawshell "${dest_file}" 2>/dev/null || true
    info "Seeded ${dest_file}."
    seeded=$((seeded + 1))
  done
done

info "Done: ${seeded} file(s) seeded, ${skipped} left untouched (already customized)."

# Install the DuckDuckGo web_search plugin (idempotent — 'plugins install' is
# safe to re-run; it no-ops if already installed). Only main/recon can
# actually see the resulting web_search tool (see config/openclaw.json5.example);
# exploit/reporter keep zero web-tool access regardless. Requires
# registry.npmjs.org to be reachable — see config/allowlist.conf. Non-fatal:
# the Gateway must already be running (this uses the openclaw-cli compose
# profile against it), so on a first-ever install this step is skipped and
# retried by re-running this script after `docker compose up -d`.
if docker compose -f compose/compose.yml ps openclaw-gateway 2>/dev/null | grep -q "Up"; then
  info "Installing DuckDuckGo web_search plugin (main/recon only)..."
  if docker compose -f compose/compose.yml run --rm openclaw-cli \
      plugins install @openclaw/duckduckgo-plugin >/tmp/duckduckgo-plugin-install.log 2>&1; then
    info "DuckDuckGo plugin installed/already present."
  else
    warn "DuckDuckGo plugin install failed — see /tmp/duckduckgo-plugin-install.log. web_search will be unavailable until this succeeds. Common cause: registry.npmjs.org not yet allowlisted in config/allowlist.conf."
  fi
else
  warn "Gateway not running yet — skipping DuckDuckGo plugin install. Re-run ./scripts/setup-team.sh after 'docker compose -f compose/compose.yml up -d' to install it."
fi

info "If the Gateway is running, restart it to pick up config/openclaw.json5: docker compose -f compose/compose.yml restart openclaw-gateway"
info "Verify the roster with: docker compose -f compose/compose.yml exec openclaw-gateway openclaw agents list --tree"
info "Submit a task to a specific agent with: ./scripts/pentest-task.sh --agent recon --repo <url> --instruction \"...\""
