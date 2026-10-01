#!/usr/bin/env bash
# Shared helpers sourced by every script in scripts/. Keep POSIX-ish bash,
# no external deps beyond coreutils/jq/docker which install.sh guarantees.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="/opt/clawshell/state"
SECRETS_DIR="/opt/clawshell/secrets"
WORKSPACES_DIR="/opt/clawshell/workspaces"
LOGS_DIR="/opt/clawshell/logs"
BACKUPS_DIR="/opt/clawshell/backups"
ENV_FILE="${REPO_ROOT}/.env"
COMPOSE_FILE="${REPO_ROOT}/compose/compose.yml"

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*" >&2; }
err()  { log "ERROR $*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root (sudo). Re-run with: sudo $0 $*"
  fi
}

require_env_file() {
  [[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} not found. Copy .env.example to .env and fill it in first."
}

# Loads .env into the current shell without exporting secrets to child
# processes beyond what's needed (Compose reads .env itself too).
load_env() {
  require_env_file
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

# Idempotently sets KEY=VALUE in .env: updates the line in place if KEY
# already exists (commented or not), else appends it. Used by install.sh to
# persist auto-detected values (e.g. AGENT_UID/AGENT_GID) without clobbering
# anything else a user has customized in .env.
set_env_var() {
  local key="$1" value="$2"
  require_env_file
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  elif grep -qE "^#\s*${key}=" "${ENV_FILE}"; then
    sed -i "s|^#\s*${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
}

check_no_placeholder_secrets() {
  load_env
  local placeholders_found=0
  # MODEL_PROVIDER_API_KEY is only required for anthropic/openai/custom.
  # local-gpu (the default) runs inference on the on-box GPU with no API key;
  # github-copilot authenticates via device-login or COPILOT_GITHUB_TOKEN
  # instead — see docs/credentials.md.
  case "${MODEL_PROVIDER:-local-gpu}" in
    local-gpu|github-copilot) : ;;
    *)
      local val="${MODEL_PROVIDER_API_KEY:-}"
      if [[ -z "${val}" || "${val}" == "REPLACE_ME" ]]; then
        err "MODEL_PROVIDER_API_KEY is not set (still a placeholder) in .env"
        placeholders_found=1
      fi
      ;;
  esac
  # GITHUB_AGENT_TOKEN is only required if the agents are expected to
  # clone/fetch/push GitHub repos (GITHUB_ALLOWED_REPOS set). Pentesting a
  # local code drop (--target <path>) needs no GitHub credential at all.
  if [[ -n "${GITHUB_ALLOWED_REPOS:-}" ]]; then
    local val="${GITHUB_AGENT_TOKEN:-}"
    if [[ -z "${val}" || "${val}" == "REPLACE_ME" ]]; then
      err "GITHUB_AGENT_TOKEN is not set (still a placeholder) in .env but GITHUB_ALLOWED_REPOS is configured"
      placeholders_found=1
    fi
  fi
  if [[ "${placeholders_found}" -eq 1 ]]; then
    die "Fill in the required secrets in .env before continuing (see docs/credentials.md, github/PROVISIONING.md)."
  fi
}

compose() {
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

# Starts/stops the caveman-proxy Compose profile service based on
# CAVEMAN_PROXY_ENABLED in .env — called after every `compose up -d` so the
# running state always matches .env instead of drifting. See
# docs/caveman-integration.md.
sync_caveman_proxy_state() {
  load_env
  if [[ "${CAVEMAN_PROXY_ENABLED:-false}" == "true" ]]; then
    info "CAVEMAN_PROXY_ENABLED=true — starting caveman-proxy."
    compose --profile caveman-proxy up -d caveman-proxy
  else
    compose --profile caveman-proxy stop caveman-proxy >/dev/null 2>&1 || true
  fi
}

# Starts/stops the local-llm (on-box GPU inference) Compose profile based on
# MODEL_PROVIDER + LOCAL_LLM_BACKEND in .env — called after every
# `compose up -d` so the running state always matches .env. A GPU profile is
# only started when MODEL_PROVIDER=local-gpu, and LOCAL_LLM_BACKEND selects the
# NVIDIA/vLLM service (local-llm, profile local-gpu) or the AMD/ROCm Ollama
# service (local-llm-amd, profile local-gpu-amd). Hosts using a hosted provider
# (or a GPU-less dev box validating config) never pull/run either. See
# docs/gpu.md.
sync_local_llm_state() {
  load_env
  if [[ "${MODEL_PROVIDER:-local-gpu}" == "local-gpu" ]]; then
    if [[ "${LOCAL_LLM_BACKEND:-nvidia}" == "amd-rocm" ]]; then
      info "MODEL_PROVIDER=local-gpu, LOCAL_LLM_BACKEND=amd-rocm — starting AMD/ROCm inference (local-llm-amd)."
      compose --profile local-gpu stop local-llm >/dev/null 2>&1 || true
      compose --profile local-gpu-amd up -d local-llm-amd
    else
      info "MODEL_PROVIDER=local-gpu, LOCAL_LLM_BACKEND=nvidia — starting on-box GPU inference (local-llm)."
      compose --profile local-gpu-amd stop local-llm-amd >/dev/null 2>&1 || true
      compose --profile local-gpu up -d local-llm
    fi
  else
    compose --profile local-gpu stop local-llm >/dev/null 2>&1 || true
    compose --profile local-gpu-amd stop local-llm-amd >/dev/null 2>&1 || true
  fi
}

confirm() {
  local prompt="${1:-Continue?}"
  read -r -p "${prompt} [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}
