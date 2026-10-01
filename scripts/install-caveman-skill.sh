#!/usr/bin/env bash
# Installs the caveman skill (https://github.com/JuliusBrussee/caveman) into
# OpenClaw's workspace. This is the OUTPUT-token-reduction half of caveman
# (terser prose in agent replies — verified upstream benchmark: ~65% fewer
# output tokens on prose-heavy replies, 0% code changed). It is a text
# skill/rule file dropped into OpenClaw's workspace (SOUL.md + skill folder)
# — no proxy, no daemon, nothing that changes network topology.
#
# Idempotent (the upstream installer itself is safe to re-run / --force).
# Runs once, at install/update time, from the host — NOT from the always-on
# Gateway's runtime network path, so it needs a *temporary* allowlist entry
# for npm/GitHub package resolution that is removed again afterwards. This
# preserves the deny-by-default egress guarantee for normal operation (see
# docs/caveman-integration.md and docs/networking.md).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh
load_env

if [[ "${CAVEMAN_SKILL_ENABLED:-true}" != "true" ]]; then
  info "CAVEMAN_SKILL_ENABLED=false, skipping caveman skill install."
  exit 0
fi

TEMP_ALLOWLIST="config/allowlist.d/zz-temp-caveman-install.conf"
cleanup() { rm -f "${TEMP_ALLOWLIST}"; }
trap cleanup EXIT

cat > "${TEMP_ALLOWLIST}" <<'EOF'
registry.npmjs.org:443
*.npmjs.org:443
codeload.github.com:443
objects.githubusercontent.com:443
EOF
info "Temporarily allowlisted npm/GitHub package hosts for the caveman skill install."

# CAVEMAN_TELEMETRY=0 / DO_NOT_TRACK=1 forced regardless of what's in .env —
# see docs/caveman-integration.md for why this repo defaults telemetry off.
# openclaw-cli's rootfs is read-only (see compose/compose.yml); point npm/npx
# caches at the container's tmpfs /tmp so the install has somewhere to write
# without needing a writable rootfs or a new volume.
compose run --rm \
  -e DO_NOT_TRACK=1 \
  -e CAVEMAN_TELEMETRY=0 \
  -e OPENCLAW_WORKSPACE=/home/node/.openclaw/workspace \
  -e HOME=/tmp \
  -e NPM_CONFIG_CACHE=/tmp/.npm-cache \
  --entrypoint sh \
  openclaw-cli \
  -c "npx -y github:JuliusBrussee/caveman -- --only openclaw --non-interactive || echo 'caveman skill install failed or already present, continuing'"

info "caveman skill install step complete. Verify with: docker compose -f compose/compose.yml run --rm openclaw-cli sh -c 'cat /home/node/.openclaw/workspace/SOUL.md' | grep -i caveman"
