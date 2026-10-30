#!/usr/bin/env bash
# Shared maintenance primitives. Caller must source common.sh first.
MAINTENANCE_LOCK=/opt/clawshell/maintenance.lock
DEPLOYMENTS_DIR=/opt/clawshell/deployments

maintenance_require() {
  local dependency
  for dependency in docker jq python3 zstd tar flock; do
    command -v "${dependency}" >/dev/null || die "Missing maintenance dependency: ${dependency}. Install it with your distribution package manager."
  done
  python3 -c 'import tarfile; assert hasattr(tarfile, "data_filter")' \
    || die "Python with tarfile.data_filter is required (use a supported, patched Python 3.11+)."
}

maintenance_lock() {
  mkdir -p /opt/clawshell
  exec {MAINTENANCE_FD}>"${MAINTENANCE_LOCK}"
  chmod 644 "${MAINTENANCE_LOCK}"
  flock -n -x "${MAINTENANCE_FD}" || die "Another backup, restore, update, or pentest is running."
}

maintenance_idle() {
  local status
  status="$(docker exec clawshell-quota-guard python3 -c \
    "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8088/status',timeout=3).read().decode())")" \
    || die "Cannot verify task status; refusing maintenance."
  jq -e 'has("active_task") and .active_task == null' <<<"${status}" >/dev/null \
    || die "A pentest is active or task status is invalid; finish/cancel it first."
  maintenance_persisted_idle
}

maintenance_persisted_idle() {
  python3 - "${STATE_DIR}/quota-guard" <<'PYCODE'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
path = root / 'state.json'
# The API also returns default empty state before the first attributed task.
if path.exists():
    state = json.loads(path.read_text())
    if not isinstance(state, dict) or 'active_task' not in state or state['active_task'] is not None:
        sys.exit('Persisted task is active or invalid; resolve it before maintenance.')
for path in (root / 'tasks').glob('*.json'):
    if json.loads(path.read_text()).get('status') == 'RUNNING':
        sys.exit('A pentest task is RUNNING; finish/cancel it before maintenance.')
PYCODE
}

maintenance_profiles() {
  PROFILES=()
  [[ "${MODEL_PROVIDER:-local-gpu}" != local-gpu ]] || {
    if [[ "${LOCAL_LLM_BACKEND:-nvidia}" == amd-rocm ]]; then
      PROFILES+=(--profile local-gpu-amd)
    else
      PROFILES+=(--profile local-gpu)
    fi
  }
  [[ "${CAVEMAN_PROXY_ENABLED:-false}" != true ]] || PROFILES+=(--profile caveman-proxy)
  # Preserve a running black-box lane; do not arm one just because the kill
  # switch permits it. New engagements start this profile themselves.
  if compose --profile blackbox-live ps --status running --services | grep -qx target-gateway; then
    PROFILES+=(--profile blackbox-live)
  fi
}

maintenance_running() {
  docker ps -q --filter label=com.docker.compose.project=clawshell
}

maintenance_wait() {
  local config="$1"; shift
  local timeout="${UPDATE_HEALTH_TIMEOUT:-600}" deadline
  [[ "${timeout}" =~ ^[1-9][0-9]*$ ]] || return 1
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if python3 "${MAINTENANCE_HELPER}" ready "${config}" "$@"; then
      return 0
    fi
    sleep 3
  done
  err "Services did not become ready within ${timeout}s."
  return 1
}

maintenance_backup() {
  local metadata="${1:-}" temporary extracted
  mkdir -p "${BACKUPS_DIR}"
  temporary="$(mktemp -d "${BACKUPS_DIR}/.backup-XXXXXXXX")"
  chmod 700 "${temporary}"
  # Caller owns cleanup of this directory even if a command fails.
  BACKUP_WORKDIR="${temporary}"
  python3 "${MAINTENANCE_HELPER}" create "${REPO_ROOT}" /opt/clawshell "${temporary}/backup.tar" ${metadata:+"${metadata}"}
  extracted="${temporary}/verify"
  mkdir "${extracted}"
  python3 "${MAINTENANCE_HELPER}" unpack "${temporary}/backup.tar" "${extracted}"
  zstd -q "${temporary}/backup.tar" -o "${temporary}/backup.tar.zst"
  BACKUP_ARCHIVE="${BACKUPS_DIR}/clawshell-$(date -u +%Y%m%dT%H%M%SZ)-${temporary##*-}.tar.zst"
  mv "${temporary}/backup.tar.zst" "${BACKUP_ARCHIVE}"
  (cd "${BACKUPS_DIR}" && sha256sum "$(basename "${BACKUP_ARCHIVE}")" > "${BACKUP_ARCHIVE}.sha256")
  info "Verified backup: ${BACKUP_ARCHIVE}"
}

maintenance_verify_archive() {
  local archive="$1" destination="$2" expected actual
  [[ -f "${archive}.sha256" ]] || die "Missing checksum: ${archive}.sha256"
  # Hash the supplied archive, never a potentially unrelated path in the sidecar.
  expected="$(awk 'NR==1 {print $1}' "${archive}.sha256")"
  [[ "${expected}" =~ ^[a-fA-F0-9]{64}$ ]] || die "Invalid checksum file."
  actual="$(sha256sum "${archive}")"
  [[ "${actual%% *}" == "${expected}" ]] || die "Backup checksum mismatch; nothing restored."
  zstd -dq -c "${archive}" > "${destination}/backup.tar"
  mkdir "${destination}/contents"
  python3 "${MAINTENANCE_HELPER}" unpack "${destination}/backup.tar" "${destination}/contents"
}

maintenance_stop() {
  # IDs are captured before stopping, so error cleanup can restart exact services.
  local running
  running="$(maintenance_running)" || return 1
  mapfile -t STOPPED_CONTAINERS <<<"${running}"
  [[ -n "${running}" ]] || die "No running deployment found."
  ((${#STOPPED_CONTAINERS[@]})) || die "No running deployment found."
  docker stop "${STOPPED_CONTAINERS[@]}" >/dev/null
  # Close the race between the initial idle check and stopping the writers.
  maintenance_persisted_idle
}

maintenance_resume() {
  if ((${#STOPPED_CONTAINERS[@]})); then
    docker start "${STOPPED_CONTAINERS[@]}" >/dev/null || return 1
    STOPPED_CONTAINERS=()
  fi
}
