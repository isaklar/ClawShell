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
PACKAGE_MANAGER=manual
ID=unknown
ID_LIKE=
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  for distro in "${ID}" ${ID_LIKE:-}; do
    case "${distro}" in
      ubuntu|debian) PACKAGE_MANAGER=apt; DOCKER_DISTRO="${distro}"; break ;;
      arch) PACKAGE_MANAGER=pacman; break ;;
      fedora)
        # Do not use Fedora's Docker repository on RHEL-like distributions.
        if [[ "${ID}" == "fedora" ]]; then PACKAGE_MANAGER=dnf; break; fi
        ;;
    esac
  done
fi
if [[ "${PACKAGE_MANAGER}" != "manual" ]]; then
  package_command="${PACKAGE_MANAGER}"
  [[ "${PACKAGE_MANAGER}" != "apt" ]] || package_command=apt-get
  command -v "${package_command}" >/dev/null 2>&1 \
    || die "Detected ${ID}, but ${package_command} is missing. Install the distribution's package manager before continuing."
  info "Installing dependencies for ${ID} using ${package_command}."
fi

case "${PACKAGE_MANAGER}" in
apt)
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg jq nftables unattended-upgrades age openssl

  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    docker_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "${docker_codename}" ]] \
      || die "No Docker repository codename found for ${ID} in /etc/os-release."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${docker_codename} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    if ! command -v docker >/dev/null 2>&1; then
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      apt-get install -y docker-compose-plugin
    fi
  else
    info "Docker and Compose already installed, skipping."
  fi
  ;;
pacman)
  # Never refresh only the package database (-Sy): Arch forbids partial upgrades.
  pacman -S --needed --noconfirm \
    ca-certificates curl gnupg jq nftables age openssl docker docker-compose \
    || die "Arch dependency installation failed. Update the host with 'pacman -Syu', resolve the package error above, then re-run install.sh."
  ;;
dnf)
  dnf install -y ca-certificates curl gnupg2 jq nftables age openssl
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    install -d -m 0755 /etc/yum.repos.d
    curl -fsSL https://download.docker.com/linux/fedora/docker-ce.repo \
      -o /etc/yum.repos.d/docker-ce.repo
    if ! command -v docker >/dev/null 2>&1; then
      dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      dnf install -y docker-compose-plugin
    fi
  else
    info "Docker and Compose already installed, skipping."
  fi
  ;;
manual)
  warn "No automatic package installation for ${ID}. Using manually installed dependencies."
  ;;
esac

for dependency in docker curl jq nft age openssl systemctl; do
  command -v "${dependency}" >/dev/null 2>&1 \
    || die "Missing dependency after package installation: ${dependency}. Install it with your distribution's package manager, then re-run install.sh."
done
docker compose version >/dev/null 2>&1 \
  || die "Docker Compose plugin is missing or not working after package installation. Resolve the package error or install the plugin, then re-run install.sh."

# --- GPU runtime for the on-box inference container (local-gpu only) --------
# NVIDIA (default): install the NVIDIA Container Toolkit so Docker can expose
# the GPU to the vLLM local-llm container.
# AMD/ROCm (LOCAL_LLM_BACKEND=amd-rocm): no toolkit needed — the Ollama ROCm
# container gets the GPU via /dev/kfd + /dev/dri device passthrough. We just
# sanity-check the devices. Skipped entirely for hosted
# providers (github-copilot/anthropic/openai/custom). See docs/gpu.md.
if [[ "${MODEL_PROVIDER:-local-gpu}" == "local-gpu" ]]; then
  if [[ "${LOCAL_LLM_BACKEND:-nvidia}" == "amd-rocm" ]]; then
    if [[ ! -e /dev/kfd || ! -e /dev/dri ]]; then
      warn "LOCAL_LLM_BACKEND=amd-rocm but /dev/kfd or /dev/dri is missing."
      warn "Install the AMD GPU driver + ROCm (amdgpu/kfd) for your Radeon card first, then re-run install.sh."
      warn "(Or switch MODEL_PROVIDER to a hosted provider in .env — see docs/credentials.md.)"
    else
      info "AMD/ROCm backend: /dev/kfd and /dev/dri present."
    fi
  elif ! command -v nvidia-smi >/dev/null 2>&1; then
    # Stop here: otherwise the NVIDIA toolkit gets installed for nothing and
    # `compose up local-llm` fails later with a far less helpful error.
    if [[ -e /dev/kfd ]]; then
      die "LOCAL_LLM_BACKEND=nvidia, but no NVIDIA driver (nvidia-smi) was found and an AMD GPU (/dev/kfd) is present. Set LOCAL_LLM_BACKEND=amd-rocm and an Ollama tag for LOCAL_LLM_MODEL (e.g. qwen2.5-coder:14b) in .env, then re-run install.sh (see docs/gpu.md)."
    fi
    die "MODEL_PROVIDER=local-gpu with LOCAL_LLM_BACKEND=nvidia, but no NVIDIA driver (nvidia-smi) was found. Install the NVIDIA driver, set LOCAL_LLM_BACKEND=amd-rocm for a Radeon card, or switch MODEL_PROVIDER to a hosted provider (docs/gpu.md, docs/credentials.md), then re-run install.sh."
  else
    # The default model (32B at full precision, ~65 GB of weights) was tuned
    # for a 96 GB card and runs out of memory on typical desktop GPUs.
    max_vram_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | sort -n | tail -1 | tr -dc '0-9' || true)"
    if [[ -n "${max_vram_mib}" && "${max_vram_mib}" -lt 80000 \
          && "${LOCAL_LLM_MODEL:-Qwen/Qwen2.5-Coder-32B-Instruct}" == "Qwen/Qwen2.5-Coder-32B-Instruct" ]]; then
      warn "Largest NVIDIA GPU has ${max_vram_mib} MiB VRAM; the default LOCAL_LLM_MODEL (Qwen/Qwen2.5-Coder-32B-Instruct, full precision) needs ~80 GB."
      warn "Pick a smaller or quantized model for LOCAL_LLM_MODEL (e.g. Qwen/Qwen2.5-Coder-7B-Instruct or Qwen/Qwen2.5-Coder-32B-Instruct-AWQ on 24 GB), see docs/gpu.md."
    fi
  fi
  if [[ "${LOCAL_LLM_BACKEND:-nvidia}" == "nvidia" ]]; then
    if ! command -v nvidia-ctk >/dev/null 2>&1; then
      info "Installing NVIDIA Container Toolkit (for GPU inference)..."
      case "${PACKAGE_MANAGER}" in
        apt)
          curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
          curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            > /etc/apt/sources.list.d/nvidia-container-toolkit.list
          apt-get update -y
          apt-get install -y nvidia-container-toolkit
          ;;
        pacman)
          pacman -S --needed --noconfirm nvidia-container-toolkit \
            || die "NVIDIA Container Toolkit installation failed. Update the Arch host with 'pacman -Syu', resolve the package error above, then re-run install.sh."
          ;;
        dnf)
          curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
            -o /etc/yum.repos.d/nvidia-container-toolkit.repo
          dnf install -y nvidia-container-toolkit
          ;;
        manual)
          die "NVIDIA Container Toolkit (nvidia-ctk) is missing. Install it with your distribution's tools, then re-run install.sh (see docs/gpu.md)."
          ;;
      esac
    else
      info "NVIDIA Container Toolkit already present, skipping installation."
    fi
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    info "NVIDIA Container Toolkit present and Docker runtime configured."
  fi
fi

if [[ "${ENABLE_UNATTENDED_UPGRADES:-true}" == "true" ]]; then
  if [[ "${PACKAGE_MANAGER}" == "apt" ]]; then
    echo 'Unattended-Upgrade::Automatic-Reboot "'"${UNATTENDED_UPGRADES_AUTO_REBOOT:-false}"'";' \
      > /etc/apt/apt.conf.d/52clawshell-auto-reboot
    systemctl enable --now unattended-upgrades.service
  else
    warn "Skipping apt-specific unattended-upgrades. Configure automatic security updates with your distribution's tools."
  fi
fi

# ---------------------------------------------------------------------------
info "Phase 3/14: System user + directories"
# ---------------------------------------------------------------------------
id -u clawshell >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin clawshell
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell
install -d -m 0700 -o clawshell -g clawshell /opt/clawshell/secrets
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/state
install -d -m 0750 -o clawshell -g clawshell /opt/clawshell/state/openclaw
# Live OpenClaw config (see Phase 7): read-only to the Gateway, writable only by
# the operator-run openclaw-cli container (models set / plugins install).
install -d -m 0755 -o clawshell -g clawshell /opt/clawshell/state/openclaw-config
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
# regardless of where this repo was cloned. A real directory here (e.g. a model
# staged into ./state/local-llm-amd before the first install) is merged into
# /opt/clawshell first; `ln -sfn` alone would nest the link inside it instead.
for d in secrets state workspaces logs backups engagement; do
  if [[ -d "${PWD}/${d}" && ! -L "${PWD}/${d}" ]]; then
    info "Migrating existing ${PWD}/${d} into /opt/clawshell/${d}."
    cp -a "${PWD}/${d}/." "/opt/clawshell/${d}/"
    rm -rf "${PWD:?}/${d}"
  fi
  ln -sfn "/opt/clawshell/${d}" "${PWD}/${d}"
done
# Compose reads .env from the compose file's directory (compose/), not the repo
# root, so plain `docker compose -f compose/compose.yml ...` would otherwise
# ignore .env (wrong AGENT_UID, default image tags, missing settings).
ln -sfn ../.env "${PWD}/compose/.env"

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
# quota-guard publishes ONLY its public egress CA certificate here (never the
# key) so the Gateway/CLI can trust its TLS interception (compose.yml mounts it).
install -d -m 0755 -o 10001 -g 10001 /opt/clawshell/state/quota-guard/public-ca

# ---------------------------------------------------------------------------
info "Phase 4/14: Docker daemon hardening"
# ---------------------------------------------------------------------------
CLAWSHELL_DOCKER_DEFAULTS='{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"5"},"userland-proxy":false}'
install -d -m 0755 /etc/docker
if [[ ! -s /etc/docker/daemon.json ]]; then
  jq . <<<"${CLAWSHELL_DOCKER_DEFAULTS}" > /etc/docker/daemon.json
  systemctl restart docker
else
  # The file may already exist (e.g. written by `nvidia-ctk runtime configure`
  # in Phase 2). Add our keys without overriding anything already set there.
  MERGED_DAEMON_JSON="$(jq --argjson d "${CLAWSHELL_DOCKER_DEFAULTS}" '$d * .' /etc/docker/daemon.json)" \
    || die "/etc/docker/daemon.json is not valid JSON. Fix it, then re-run install.sh."
  if [[ "$(jq -S . /etc/docker/daemon.json)" != "$(jq -S . <<<"${MERGED_DAEMON_JSON}")" ]]; then
    cp /etc/docker/daemon.json "/opt/clawshell/backups/daemon.json.$(date +%s)"
    printf '%s\n' "${MERGED_DAEMON_JSON}" > /etc/docker/daemon.json
    info "Merged clawshell defaults into existing /etc/docker/daemon.json (existing values kept)."
    systemctl restart docker
  else
    info "/etc/docker/daemon.json already contains the clawshell defaults."
  fi
fi
systemctl enable --now docker

# ---------------------------------------------------------------------------
info "Phase 5/14: Firewall (nftables)"
# ---------------------------------------------------------------------------
# All rules live in a dedicated `table inet clawshell`, loaded by
# clawshell-firewall.service from /etc/clawshell/nftables.conf. The host's
# /etc/nftables.conf, Docker's rules, and firewalld/ufw are never touched.
FIREWALL_INPUT_POLICY="${FIREWALL_INPUT_POLICY:-drop}"
case "${FIREWALL_INPUT_POLICY}" in
  drop|accept) ;;
  *) die "FIREWALL_INPUT_POLICY must be 'drop' or 'accept' (got '${FIREWALL_INPUT_POLICY}')." ;;
esac
RENDERED_RULESET="$(mktemp)"
sed -e "s|__SSH_PORT__|${SSH_PORT:-22}|g" \
    -e "s|__SSH_ALLOW_CIDR__|${SSH_ALLOW_CIDR:-0.0.0.0/0}|g" \
    -e "s|__LAN_ALLOW_CIDR__|${LAN_ALLOW_CIDR:-192.168.0.0/16}|g" \
    -e "s|__LAN_ALLOW_CIDR6__|${LAN_ALLOW_CIDR6:-::1/128}|g" \
    -e "s|__OPENCLAW_GATEWAY_PORT__|${OPENCLAW_GATEWAY_PORT:-18789}|g" \
    -e "s|__INPUT_POLICY__|${FIREWALL_INPUT_POLICY}|g" \
    firewall/nftables.conf.template > "${RENDERED_RULESET}"
if [[ "${FIREWALL_INPUT_POLICY}" == "accept" ]]; then
  # Nothing is dropped by policy in accept mode, so the catch-all log would
  # log every accepted inbound packet.
  sed -i '/nft-input-drop/d' "${RENDERED_RULESET}"
fi

echo "----- Proposed nftables ruleset (table inet clawshell) -----"
cat "${RENDERED_RULESET}"
echo "------------------------------------------------------------"
info "FIREWALL_INPUT_POLICY=${FIREWALL_INPUT_POLICY}. Use 'accept' on a shared desktop so other inbound services keep working."

# Older releases overwrote /etc/nftables.conf (with `flush ruleset`); put the
# host's original back so it no longer wipes Docker's rules on boot.
if grep -q 'clawshell nftables ruleset template' /etc/nftables.conf 2>/dev/null; then
  LEGACY_BACKUP="$(ls -t /opt/clawshell/backups/nftables.conf.pre-install.* 2>/dev/null | head -1 || true)"
  if [[ -n "${LEGACY_BACKUP}" ]]; then
    cp "${LEGACY_BACKUP}" /etc/nftables.conf
    info "Restored the host's original /etc/nftables.conf from ${LEGACY_BACKUP} (legacy clawshell ruleset)."
  else
    warn "/etc/nftables.conf still holds a legacy clawshell ruleset and no pre-install backup exists; review it manually."
  fi
fi

if [[ -f /etc/nftables.conf ]] && grep -q '^[[:space:]]*flush ruleset' /etc/nftables.conf \
   && systemctl is-enabled --quiet nftables 2>/dev/null; then
  warn "nftables.service is enabled and /etc/nftables.conf starts with 'flush ruleset'."
  warn "Reloading it removes Docker's rules (and this table until clawshell-firewall reloads). Consider disabling nftables.service if nothing else needs it."
fi

if confirm "Apply this firewall ruleset now? (Your current SSH session stays allowed via SSH_ALLOW_CIDR)"; then
  nft -c -f "${RENDERED_RULESET}" \
    || die "nftables ruleset failed syntax check (nft -c). Not applying. Check firewall/nftables.conf.template."
  install -d -m 0755 /etc/clawshell
  if [[ -f /etc/clawshell/nftables.conf ]]; then
    cp /etc/clawshell/nftables.conf "/opt/clawshell/backups/clawshell-nftables.conf.$(date +%s)"
  fi
  # `nft -f` is atomic: on failure nothing changes and the previous table stays loaded.
  if nft -f "${RENDERED_RULESET}"; then
    install -m 0644 "${RENDERED_RULESET}" /etc/clawshell/nftables.conf
    install -m 0644 systemd/clawshell-firewall.service /etc/systemd/system/clawshell-firewall.service
    systemctl daemon-reload
    systemctl enable clawshell-firewall.service
    info "Firewall applied (table inet clawshell)."
  else
    die "New ruleset failed to load; the previously loaded ruleset is unchanged."
  fi
else
  warn "Skipped firewall step at your request. Re-run install.sh later to apply it."
fi
rm -f "${RENDERED_RULESET}"

# ---------------------------------------------------------------------------
info "Phase 6/14: Secrets"
# ---------------------------------------------------------------------------
write_secret() {
  local name="$1" value="$2"
  local path="/opt/clawshell/secrets/${name}"
  # The .env.example placeholder means "not configured": store it as empty so
  # nothing downstream mistakes it for a real credential.
  [[ "${value}" != "REPLACE_ME" ]] || value=""
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
LIVE_OPENCLAW_CONFIG=/opt/clawshell/state/openclaw-config/openclaw.json5
if [[ -f config/openclaw.json5 && ! -L config/openclaw.json5 ]]; then
  # A repo-local regular file (first install, or edited before re-running):
  # it becomes the live config. Keep any previous live copy as a backup.
  if [[ -f "${LIVE_OPENCLAW_CONFIG}" ]]; then
    cp -a "${LIVE_OPENCLAW_CONFIG}" "/opt/clawshell/backups/openclaw.json5.$(date +%Y%m%d%H%M%S)"
  fi
  install -m 0644 -o clawshell -g clawshell config/openclaw.json5 "${LIVE_OPENCLAW_CONFIG}"
  rm -f config/openclaw.json5
elif [[ ! -f "${LIVE_OPENCLAW_CONFIG}" ]]; then
  install -m 0644 -o clawshell -g clawshell config/openclaw.json5.example "${LIVE_OPENCLAW_CONFIG}"
fi
# The live file lives in a directory mounted read-only into the Gateway and
# writable into openclaw-cli, so `openclaw-cli models set` / `plugins install`
# persist (a single-file :ro mount made them fail). Editing config/openclaw.json5
# in the repo still works through this symlink.
ln -sfn "${LIVE_OPENCLAW_CONFIG}" config/openclaw.json5
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
# Phase 8 ran before the Gateway existed, so the DuckDuckGo plugin step was
# skipped there. Retry now that it's up, then restart so the Gateway loads it.
if scripts/setup-team.sh; then
  compose restart openclaw-gateway || warn "Gateway restart after plugin install failed — restart it manually."
else
  warn "Agent team / plugin setup failed — non-fatal. Re-run ./scripts/setup-team.sh later."
fi

# ---------------------------------------------------------------------------
info "Phase 11/14: Model provider auth / model selection"
# ---------------------------------------------------------------------------
# Config-writing OpenClaw commands go through openclaw-cli: the Gateway's
# config mount is read-only (OPENCLAW_CONFIG_READONLY=1). Restart the Gateway
# afterwards so it loads the change.
CLI="docker compose -f compose/compose.yml run --rm openclaw-cli"
if [[ "${MODEL_PROVIDER:-local-gpu}" == "local-gpu" ]]; then
  if [[ "${LOCAL_LLM_BACKEND:-nvidia}" == "amd-rocm" ]]; then
    info "MODEL_PROVIDER=local-gpu, LOCAL_LLM_BACKEND=amd-rocm — on-box AMD/ROCm inference, no external auth needed."
    info "The local-llm-amd (Ollama) container serves '${LOCAL_LLM_MODEL:-qwen2.5-coder:14b}' on the AMD GPU."
    if [[ -z "$(ls -A /opt/clawshell/state/local-llm-amd/models 2>/dev/null)" ]]; then
      warn "No model staged in /opt/clawshell/state/local-llm-amd — the inference network has NO internet, so"
      warn "Ollama cannot download it itself. Stage it once (this one-off container has internet):"
      warn "  sudo docker run --rm -v /opt/clawshell/state/local-llm-amd:/root/.ollama --entrypoint /bin/sh ${LOCAL_LLM_AMD_IMAGE:-ollama/ollama:rocm} -c 'ollama serve & sleep 3; ollama pull ${LOCAL_LLM_MODEL:-qwen2.5-coder:14b}'"
      warn "  sudo docker compose -f compose/compose.yml --profile local-gpu-amd restart local-llm-amd"
    fi
    info "Watch with: sudo docker compose -f compose/compose.yml --profile local-gpu-amd logs -f local-llm-amd"
    info "Then point OpenClaw at it (NATIVE ollama provider — NOT /v1):"
    info "  sudo ${CLI} models set ollama/${LOCAL_LLM_MODEL:-qwen2.5-coder:14b}"
    info "  sudo docker compose -f compose/compose.yml restart openclaw-gateway"
    info "See docs/gpu.md for VRAM-appropriate model tags and docs/credentials.md."
  else
    info "MODEL_PROVIDER=local-gpu, LOCAL_LLM_BACKEND=nvidia — on-box GPU inference, no external auth needed."
    if [[ -z "$(ls -A /opt/clawshell/state/local-llm/hub 2>/dev/null)" ]]; then
      warn "No model weights staged in /opt/clawshell/state/local-llm — the inference network has NO internet, so"
      warn "vLLM cannot download '${LOCAL_LLM_MODEL:-Qwen/Qwen2.5-Coder-32B-Instruct}' itself. Stage it once (this one-off container has internet):"
      warn "  sudo docker run --rm -v /opt/clawshell/state/local-llm:/root/.cache/huggingface -e HUGGING_FACE_HUB_TOKEN --entrypoint python3 ${LOCAL_LLM_IMAGE:-vllm/vllm-openai:v0.30.0} -c \"from huggingface_hub import snapshot_download; snapshot_download('${LOCAL_LLM_MODEL:-Qwen/Qwen2.5-Coder-32B-Instruct}')\""
      warn "  sudo docker compose -f compose/compose.yml --profile local-gpu restart local-llm"
    fi
    info "Loading weights onto the GPU can take several minutes. Watch with:"
    info "  sudo docker compose -f compose/compose.yml --profile local-gpu logs -f local-llm"
    info "Then point OpenClaw at it (OpenAI-compatible, served as '${LOCAL_LLM_SERVED_NAME:-clawshell-local}'):"
    info "  sudo ${CLI} models set local/${LOCAL_LLM_SERVED_NAME:-clawshell-local}"
    info "  sudo docker compose -f compose/compose.yml restart openclaw-gateway"
    info "See docs/gpu.md and docs/credentials.md."
  fi
elif [[ "${MODEL_PROVIDER:-local-gpu}" == "github-copilot" ]]; then
  sleep 3
  if compose exec -T openclaw-gateway openclaw models auth status --provider github-copilot >/dev/null 2>&1; then
    info "GitHub Copilot already authenticated (existing auth profile found)."
  elif [[ -n "${COPILOT_GITHUB_TOKEN:-}" ]]; then
    info "COPILOT_GITHUB_TOKEN set — using non-interactive Copilot auth."
    if compose run --rm -T openclaw-cli \
      onboard --non-interactive --accept-risk \
      --auth-choice github-copilot \
      --github-copilot-token "${COPILOT_GITHUB_TOKEN}" \
      --skip-channels --skip-health; then
      compose restart openclaw-gateway || true
    else
      warn "Non-interactive Copilot auth failed. Run manually: sudo ${CLI} models auth login-github-copilot"
    fi
  else
    warn "No GitHub Copilot auth profile found and COPILOT_GITHUB_TOKEN is unset."
    warn "MANUAL STEP REQUIRED (one-time, interactive): run"
    warn "  sudo ${CLI} models auth login-github-copilot"
    warn "then follow the device-login URL/code, and set a default model with"
    warn "  sudo ${CLI} models set github-copilot/<model>"
    warn "  sudo docker compose -f compose/compose.yml restart openclaw-gateway"
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
