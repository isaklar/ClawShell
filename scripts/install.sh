#!/usr/bin/env bash
# clawshell installer. Idempotent, safe to re-run. See docs/operations.md
# for the full phase breakdown and docs/architecture.md for the "why".
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

CONFIRM_RESET=0
for arg in "$@"; do
  case "${arg}" in
    --confirm-reset) CONFIRM_RESET=1 ;;
    --rotate-gateway-token) ROTATE_TOKEN=1 ;;
  esac
done

require_root

# ---------------------------------------------------------------------------
info "Phase 1/14: Preflight"
# ---------------------------------------------------------------------------
if ! command -v apt-get >/dev/null 2>&1; then
  warn "This convenience installer targets the Debian/Ubuntu family (apt). On other Linux distributions, install Docker Engine + Compose, nftables, jq, and age with your package manager, then the platform itself runs unchanged (it only needs Docker + systemd)."
fi
if [[ "$(uname -m)" != "x86_64" ]]; then
  warn "Non-x86_64 architecture detected ($(uname -m)). Untested target."
fi
[[ -f .env ]] || die "No .env found. Run: cp .env.example .env && \$EDITOR .env, then re-run this script."
check_no_placeholder_secrets
load_env

CURRENT_SSH_CLIENT_IP="$(echo "${SSH_CLIENT:-} ${SSH_CONNECTION:-}" | awk '{print $1}')"
info "Preflight OK. Detected SSH client IP: ${CURRENT_SSH_CLIENT_IP:-none (local console session)}"

# ---------------------------------------------------------------------------
info "Phase 2/14: Packages"
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq nftables unattended-upgrades age

if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  curl -fsSL "https://download.docker.com/linux/${ID:-ubuntu}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID:-ubuntu} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  info "Docker already installed, skipping."
fi

# --- GPU runtime for the on-box inference container (local-gpu only) --------
# NVIDIA (default): install the NVIDIA Container Toolkit so Docker can expose
# the GPU to the vLLM local-llm container.
# AMD/ROCm (LOCAL_LLM_BACKEND=amd-rocm): no toolkit needed — the Ollama ROCm
# container gets the GPU via /dev/kfd + /dev/dri device passthrough. We just
# sanity-check the devices and group membership. Skipped entirely for hosted
# providers (github-copilot/anthropic/openai/custom). See docs/gpu.md.
if [[ "${MODEL_PROVIDER:-local-gpu}" == "local-gpu" ]]; then
  if [[ "${LOCAL_LLM_BACKEND:-nvidia}" == "amd-rocm" ]]; then
    if [[ ! -e /dev/kfd || ! -e /dev/dri ]]; then
      warn "LOCAL_LLM_BACKEND=amd-rocm but /dev/kfd or /dev/dri is missing."
      warn "Install the AMD GPU driver + ROCm (amdgpu/kfd) for your Radeon card first, then re-run install.sh."
      warn "(Or switch MODEL_PROVIDER to a hosted provider in .env — see docs/credentials.md.)"
    else
      info "AMD/ROCm backend: /dev/kfd and /dev/dri present."
      if command -v getent >/dev/null 2>&1; then
        info "render group: $(getent group render || echo 'not found') / video group: $(getent group video || echo 'not found')"
        info "If the container hits GPU permission errors, set numeric render/video GIDs in compose/compose.yml (group_add)."
      fi
    fi
  elif ! command -v nvidia-smi >/dev/null 2>&1; then
    warn "MODEL_PROVIDER=local-gpu but no NVIDIA driver (nvidia-smi) was found."
    warn "Install the NVIDIA GPU driver for your RTX 6000 Ada first, then re-run install.sh."
    warn "(Or set LOCAL_LLM_BACKEND=amd-rocm for a Radeon card, or switch MODEL_PROVIDER to a hosted provider — see docs/gpu.md.)"
  fi
  if [[ "${LOCAL_LLM_BACKEND:-nvidia}" == "nvidia" ]]; then
    if ! command -v nvidia-ctk >/dev/null 2>&1; then
      info "Installing NVIDIA Container Toolkit (for GPU inference)..."
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list
      apt-get update -y
      apt-get install -y nvidia-container-toolkit
      nvidia-ctk runtime configure --runtime=docker
      systemctl restart docker || true
      info "NVIDIA Container Toolkit installed and Docker runtime configured."
    else
      info "NVIDIA Container Toolkit already present, skipping."
    fi
  fi
fi

if [[ "${ENABLE_UNATTENDED_UPGRADES:-true}" == "true" ]]; then
  echo 'Unattended-Upgrade::Automatic-Reboot "'"${UNATTENDED_UPGRADES_AUTO_REBOOT:-false}"'";' \
    > /etc/apt/apt.conf.d/52clawshell-auto-reboot
  systemctl enable --now unattended-upgrades.service
fi

# ---------------------------------------------------------------------------
info "Phase 3/14: System user + directories"
# ---------------------------------------------------------------------------
id -u clawshell >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin clawshell
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell
install -d -m 0700 -o clawshell -g clawshell /opt/clawshell/secrets
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/state
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/state/openclaw
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/state/quota-guard
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/state/sandbox-dind
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/state/caveman
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/state/local-llm
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/state/local-llm-amd
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/workspaces
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/workspaces/reports
# Engagement inputs (read-only to the agents via the :ro mount in compose.yml):
# the target code under test and, optionally, the requirement spec. The spec is
# normally attached directly in the OpenClaw chat UI instead (see docs/pentest-team.md).
install -d -m 0755 -o clawshell -g clawshell /opt/clawshell/engagement
install -d -m 0755 -o clawshell -g clawshell /opt/clawshell/engagement/target
install -d -m 0755 -o clawshell -g clawshell /opt/clawshell/engagement/spec
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/logs
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/logs/quota-guard
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/backups
# Bind-mount friendly symlinks so compose.yml's relative `../state` etc. resolve
# regardless of where this repo was cloned.
for d in secrets state workspaces logs backups engagement; do
  ln -sfn "/opt/clawshell/${d}" "${PWD}/${d}"
done

# --- UID/GID reconciliation ------------------------------------------------
# `useradd --system` lets the OS assign whatever UID/GID is free; it is NOT
# guaranteed to be 1000, and it's re-derived here on every run (idempotent)
# so an existing install picks up the right values too. Persisted to .env so
# compose.yml can run openclaw-gateway/openclaw-cli as this exact user
# (matters for files those containers write into bind-mounted host dirs).
AGENT_UID="$(id -u clawshell)"
AGENT_GID="$(id -g clawshell)"
set_env_var AGENT_UID "${AGENT_UID}"
set_env_var AGENT_GID "${AGENT_GID}"
info "clawshell system user: uid=${AGENT_UID} gid=${AGENT_GID} (persisted to .env as AGENT_UID/AGENT_GID)"

# quota-guard's own image bakes in a fixed non-configurable UID/GID 10001
# (see quota-guard/Dockerfile: `useradd --uid 10001 ... quotaguard`), and
# sandbox-dind's upstream image (docker:27-dind-rootless) bakes in a fixed
# rootless UID/GID 1000 -- both independent of whatever clawshell's own
# UID ends up being. Their host-mounted state/log dirs must be owned to
# match those fixed in-container users, not clawshell's UID, or those
# containers will fail with permission-denied on first write.
chown -R 10001:10001 /opt/clawshell/state/quota-guard /opt/clawshell/logs/quota-guard
chown -R 1000:1000 /opt/clawshell/state/sandbox-dind

# ---------------------------------------------------------------------------
info "Phase 4/14: Docker daemon hardening"
# ---------------------------------------------------------------------------
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" },
  "userland-proxy": false
}
JSON
  systemctl restart docker
else
  info "/etc/docker/daemon.json already exists, leaving it as-is."
fi
systemctl enable --now docker

# ---------------------------------------------------------------------------
info "Phase 5/14: Firewall (nftables)"
# ---------------------------------------------------------------------------
RENDERED_RULESET="$(mktemp)"
sed -e "s|__SSH_PORT__|${SSH_PORT:-22}|g" \
    -e "s|__SSH_ALLOW_CIDR__|${SSH_ALLOW_CIDR:-0.0.0.0/0}|g" \
    -e "s|__LAN_ALLOW_CIDR__|${LAN_ALLOW_CIDR:-192.168.0.0/16}|g" \
    -e "s|__OPENCLAW_GATEWAY_PORT__|${OPENCLAW_GATEWAY_PORT:-18789}|g" \
    firewall/nftables.conf.template > "${RENDERED_RULESET}"

echo "----- Proposed nftables ruleset -----"
cat "${RENDERED_RULESET}"
echo "--------------------------------------"

if [[ -f /etc/nftables.conf ]]; then
  cp /etc/nftables.conf "/opt/clawshell/backups/nftables.conf.pre-install.$(date +%s)"
fi

if confirm "Apply this firewall ruleset now? (Your current SSH session stays allowed via SSH_ALLOW_CIDR)"; then
  if nft -c -f "${RENDERED_RULESET}"; then
    cp "${RENDERED_RULESET}" /etc/nftables.conf
    if ! nft -f /etc/nftables.conf; then
      err "New ruleset failed to load, reverting to previous ruleset."
      [[ -f "/opt/clawshell/backups/nftables.conf.pre-install."* ]] && nft -f "$(ls -t /opt/clawshell/backups/nftables.conf.pre-install.* | head -1)"
    else
      systemctl enable nftables
      info "Firewall applied."
    fi
  else
    die "nftables ruleset failed syntax check (nft -c). Not applying. Check firewall/nftables.conf.template."
  fi
else
  warn "Skipped firewall step at your request. Re-run install.sh later to apply it."
fi

# ---------------------------------------------------------------------------
info "Phase 6/14: Secrets"
# ---------------------------------------------------------------------------
write_secret() {
  local name="$1" value="$2"
  local path="/opt/clawshell/secrets/${name}"
  # Always create the file (even empty) so compose's `secrets: file:` mount
  # doesn't fail for optional secrets (e.g. copilot_github_token) that are
  # legitimately unset.
  printf '%s' "${value}" > "${path}"
  chmod 600 "${path}"
  chown clawshell:clawshell "${path}"
}
write_secret model_provider_api_key "${MODEL_PROVIDER_API_KEY:-}"
write_secret github_agent_token "${GITHUB_AGENT_TOKEN:-}"

GATEWAY_TOKEN_FILE="/opt/clawshell/secrets/gateway_token"
if [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
  # Honor an explicit token from .env (e.g. pinned for a known Control UI
  # bookmark/integration) instead of always generating a fresh one.
  printf '%s' "${OPENCLAW_GATEWAY_TOKEN}" > "${GATEWAY_TOKEN_FILE}"
  chmod 600 "${GATEWAY_TOKEN_FILE}"
  chown clawshell:clawshell "${GATEWAY_TOKEN_FILE}"
  info "Using OPENCLAW_GATEWAY_TOKEN from .env."
elif [[ ! -s "${GATEWAY_TOKEN_FILE}" || "${ROTATE_TOKEN:-0}" == "1" ]]; then
  openssl rand -hex 32 > "${GATEWAY_TOKEN_FILE}"
  chmod 600 "${GATEWAY_TOKEN_FILE}"
  chown clawshell:clawshell "${GATEWAY_TOKEN_FILE}"
  info "Generated a new Gateway auth token."
fi

# ---------------------------------------------------------------------------
info "Phase 7/14: Config files"
# ---------------------------------------------------------------------------
[[ -f config/openclaw.json5 ]] || cp config/openclaw.json5.example config/openclaw.json5
mkdir -p config/allowlist.d

# ---------------------------------------------------------------------------
info "Phase 8/14: Agent team workspaces (see docs/pentest-team.md)"
# ---------------------------------------------------------------------------
# Seeds AGENTS.md for the default 4-agent team (main=researcher/architect,
# recon, exploit, reporter) declared in config/openclaw.json5. Idempotent
# and never overwrites an already-customized workspace file. If you removed
# the extra agents.entries from your config/openclaw.json5, this is harmless
# — the unused workspace dirs just sit empty.
scripts/setup-team.sh || warn "Agent team workspace seeding failed/skipped — non-fatal, continuing."

# ---------------------------------------------------------------------------
info "Phase 9/14: Build/pull images"
# ---------------------------------------------------------------------------
compose build quota-guard
compose pull openclaw-gateway openclaw-cli || warn "Pull failed/skipped (offline install? use --offline docs later)."

# ---------------------------------------------------------------------------
info "Phase 10/14: Start services"
# ---------------------------------------------------------------------------
compose up -d
sync_caveman_proxy_state
sync_local_llm_state

# ---------------------------------------------------------------------------
info "Phase 11/14: Model provider auth / model selection"
# ---------------------------------------------------------------------------
if [[ "${MODEL_PROVIDER:-local-gpu}" == "local-gpu" ]]; then
  if [[ "${LOCAL_LLM_BACKEND:-nvidia}" == "amd-rocm" ]]; then
    info "MODEL_PROVIDER=local-gpu, LOCAL_LLM_BACKEND=amd-rocm — on-box AMD/ROCm inference, no external auth needed."
    info "The local-llm-amd (Ollama) container serves '${LOCAL_LLM_MODEL:-qwen2.5-coder:14b}' on the AMD GPU."
    info "NOTE: the inference network has no egress — pre-stage the model into state/local-llm-amd first (see docs/gpu.md). Watch with:"
    info "  docker compose -f compose/compose.yml --profile local-gpu-amd logs -f local-llm-amd"
    info "Then point OpenClaw at it (NATIVE ollama provider — NOT /v1):"
    info "  docker compose -f compose/compose.yml exec openclaw-gateway openclaw models set ollama/${LOCAL_LLM_MODEL:-qwen2.5-coder:14b}"
    info "See docs/gpu.md for VRAM-appropriate model tags and docs/credentials.md."
  else
    info "MODEL_PROVIDER=local-gpu, LOCAL_LLM_BACKEND=nvidia — on-box GPU inference, no external auth needed."
    info "The local-llm container is loading '${LOCAL_LLM_MODEL:-Qwen/Qwen2.5-Coder-32B-Instruct}' onto the GPU;"
    info "first start can take several minutes while weights download/load. Watch with:"
    info "  docker compose -f compose/compose.yml --profile local-gpu logs -f local-llm"
    info "Then point OpenClaw at it (OpenAI-compatible, served as '${LOCAL_LLM_SERVED_NAME:-clawshell-local}'):"
    info "  docker compose -f compose/compose.yml exec openclaw-gateway openclaw models set local/${LOCAL_LLM_SERVED_NAME:-clawshell-local}"
    info "See docs/gpu.md and docs/credentials.md."
  fi
elif [[ "${MODEL_PROVIDER:-local-gpu}" == "github-copilot" ]]; then
  sleep 3
  if compose exec -T openclaw-gateway openclaw models auth status --provider github-copilot >/dev/null 2>&1; then
    info "GitHub Copilot already authenticated (existing auth profile found)."
  elif [[ -n "${COPILOT_GITHUB_TOKEN:-}" ]]; then
    info "COPILOT_GITHUB_TOKEN set — using non-interactive Copilot auth."
    compose exec -T openclaw-gateway \
      openclaw onboard --non-interactive --accept-risk \
      --auth-choice github-copilot \
      --github-copilot-token "${COPILOT_GITHUB_TOKEN}" \
      --skip-channels --skip-health \
      || warn "Non-interactive Copilot auth failed. Run manually: docker compose -f compose/compose.yml exec openclaw-gateway openclaw models auth login-github-copilot"
  else
    warn "No GitHub Copilot auth profile found and COPILOT_GITHUB_TOKEN is unset."
    warn "MANUAL STEP REQUIRED (one-time, interactive): run"
    warn "  docker compose -f compose/compose.yml exec openclaw-gateway openclaw models auth login-github-copilot"
    warn "then follow the device-login URL/code, and set a default model with"
    warn "  docker compose -f compose/compose.yml exec openclaw-gateway openclaw models set github-copilot/<model>"
    warn "The agent cannot make AI calls until this is done. See docs/credentials.md."
  fi
else
  info "MODEL_PROVIDER=${MODEL_PROVIDER} — using a hosted API key; skipping GPU/device-login steps."
fi

# ---------------------------------------------------------------------------
info "Phase 12/14: Caveman skill (token reduction, see docs/caveman-integration.md)"
# ---------------------------------------------------------------------------
scripts/install-caveman-skill.sh || warn "Caveman skill install failed/skipped — non-fatal, continuing."

# ---------------------------------------------------------------------------
info "Phase 13/14: Verify"
# ---------------------------------------------------------------------------
sleep 5
if ! scripts/healthcheck.sh --exit-code; then
  die "Healthcheck failed after install. See output above and 'docker compose -f compose/compose.yml logs'."
fi

# ---------------------------------------------------------------------------
info "Phase 14/14: systemd"
# ---------------------------------------------------------------------------
sed "s|__REPO_ROOT__|${PWD}|g" systemd/clawshell.service.template > /etc/systemd/system/clawshell.service
sed "s|__REPO_ROOT__|${PWD}|g" systemd/clawshell-healthcheck.service.template > /etc/systemd/system/clawshell-healthcheck.service
sed "s|__REPO_ROOT__|${PWD}|g" systemd/clawshell-backup.service.template > /etc/systemd/system/clawshell-backup.service
cp systemd/clawshell-healthcheck.timer /etc/systemd/system/clawshell-healthcheck.timer
cp systemd/clawshell-backup.timer /etc/systemd/system/clawshell-backup.timer
systemctl daemon-reload
systemctl enable --now clawshell.service
systemctl enable --now clawshell-healthcheck.timer
systemctl enable --now clawshell-backup.timer

info "Install complete."
info "Control UI: http://<this-host-lan-ip>:${OPENCLAW_GATEWAY_PORT:-18789}/"
info "Gateway token: /opt/clawshell/secrets/gateway_token (readable by root/clawshell only)"
info "Run ./scripts/healthcheck.sh any time for a status summary."
