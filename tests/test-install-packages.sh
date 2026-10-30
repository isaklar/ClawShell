#!/usr/bin/env bash
# Exercise the installer's package phase with mocked host tools, no root/network.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
mkdir -p "${tmpdir}/etc/apt/"{keyrings,sources.list.d,apt.conf.d} \
  "${tmpdir}/etc/yum.repos.d" "${tmpdir}/usr/share/keyrings"

# Redirect every system-path write into the test directory, even on regressions.
awk '/info "Phase 2\/14:/ { active=1 }
     /info "Phase 3\/14:/ { exit }
     active { print }' scripts/install.sh \
  | sed -e "s|/etc/|${tmpdir}/etc/|g" \
        -e "s|/usr/share/|${tmpdir}/usr/share/|g" > "${tmpdir}/packages.sh"
[[ -s "${tmpdir}/packages.sh" ]]

FAIL=0
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; cat "${tmpdir}/output"; FAIL=1; }

run_phase() {
  env HAS_APT=0 HAS_PACMAN=0 HAS_DNF=0 MISSING_COMMAND= COMPOSE_STATUS=0 \
    PACKAGE_STATUS=0 INSTALL_REPAIRS=1 SYSTEMCTL_STATUS=0 TEST_OS_RELEASE=ID=unknown \
    MODEL_PROVIDER=openai LOCAL_LLM_BACKEND=nvidia \
    ENABLE_UNATTENDED_UPGRADES=true "$@" bash -c '
    set -euo pipefail
    info() { printf "INFO %s\n" "$*"; }
    warn() { printf "WARN %s\n" "$*" >&2; }
    die()  { printf "ERROR %s\n" "$*" >&2; exit 1; }
    command() {
      if [[ "$1" == "-v" ]]; then
        [[ "$2" != "${MISSING_COMMAND}" ]] || return 1
        case "$2" in
          apt-get) [[ "${HAS_APT}" == "1" ]]; return ;;
          pacman)  [[ "${HAS_PACMAN}" == "1" ]]; return ;;
          dnf)     [[ "${HAS_DNF}" == "1" ]]; return ;;
        esac
      fi
      builtin command "$@"
    }
    packages() {
      info "$*"
      [[ "${PACKAGE_STATUS}" == "0" ]] || return "${PACKAGE_STATUS}"
      if [[ "${INSTALL_REPAIRS}" == "1" ]]; then
        case " $* " in
          *" docker "*|*" docker-ce "*) [[ "${MISSING_COMMAND}" != "docker" ]] || MISSING_COMMAND= ;;
        esac
        case " $* " in
          *" docker-compose "*|*" docker-compose-plugin "*) COMPOSE_STATUS=0 ;;
        esac
        case " $* " in
          *" nvidia-container-toolkit "*) [[ "${MISSING_COMMAND}" != "nvidia-ctk" ]] || MISSING_COMMAND= ;;
        esac
      fi
      return 0
    }
    apt-get()   { packages apt-get "$@"; }
    pacman()    { packages pacman "$@"; }
    dnf()       { packages dnf "$@"; }
    docker()    { info "docker $*"; return "${COMPOSE_STATUS}"; }
    curl()      { info "curl $*"; }
    jq()        { :; }
    nft()       { :; }
    age()       { :; }
    openssl()   { :; }
    systemctl() { info "systemctl $*"; return "${SYSTEMCTL_STATUS}"; }
    nvidia-smi(){ :; }
    nvidia-ctk(){ info "nvidia-ctk $*"; }
    gpg()       { cat >/dev/null; }
    install()   { info "install $*"; }
    chmod()     { info "chmod $*"; }
    dpkg()      { printf "amd64\n"; }
    printf "%s\n" "${TEST_OS_RELEASE}" > "$2"
    source "$1"
    info "PACKAGES_COMPLETE"
  ' _ "${tmpdir}/packages.sh" "${tmpdir}/etc/os-release" > "${tmpdir}/output" 2>&1
}

expect_success() {
  local label="$1"; shift
  if run_phase "$@" && grep -q 'PACKAGES_COMPLETE' "${tmpdir}/output"; then
    ok "${label}"
  else
    bad "${label}"
  fi
}

expect_failure() {
  local label="$1" message="$2"; shift 2
  if run_phase "$@"; then
    bad "${label}: unexpectedly succeeded"
  elif grep -qF "${message}" "${tmpdir}/output"; then
    ok "${label}"
  else
    bad "${label}: missing actionable error"
  fi
}

expect_success "Unsupported host continues with manually installed dependencies"
if grep -qE 'INFO (apt-get (update|install)|pacman |dnf |curl |systemctl )' "${tmpdir}/output" \
  || [[ -e "${tmpdir}/etc/apt/apt.conf.d/52clawshell-auto-reboot" ]]; then
  bad "Unsupported host must not install packages or configure unattended-upgrades"
elif grep -q 'Skipping apt-specific unattended-upgrades' "${tmpdir}/output"; then
  ok "Non-apt host explicitly skips unattended-upgrades without host changes"
else
  bad "Non-apt host must warn about skipped unattended-upgrades"
fi

expect_success "Unsupported NVIDIA host with installed toolkit continues" MODEL_PROVIDER=local-gpu
if ! grep -q 'nvidia-ctk runtime configure --runtime=docker' "${tmpdir}/output"; then
  bad "Already installed NVIDIA toolkit must also be configured automatically"
fi
expect_success "Unsupported AMD host needs no NVIDIA toolkit" MODEL_PROVIDER=local-gpu \
  LOCAL_LLM_BACKEND=amd-rocm MISSING_COMMAND=nvidia-ctk
expect_failure "Unsupported NVIDIA host missing toolkit stops with instructions" \
  "NVIDIA Container Toolkit (nvidia-ctk) is missing" MODEL_PROVIDER=local-gpu \
  MISSING_COMMAND=nvidia-ctk

for dependency in docker curl jq nft age openssl systemctl python3 zstd tar flock; do
  expect_failure "Missing ${dependency} stops before later phases" \
    "Missing dependency after package installation: ${dependency}" "MISSING_COMMAND=${dependency}"
done
expect_failure "Missing Compose stops with instructions" \
  "Docker Compose plugin is missing or not working" COMPOSE_STATUS=1

ubuntu=$'ID=ubuntu\nVERSION_CODENAME=noble'
debian=$'ID=debian\nVERSION_CODENAME=bookworm'
arch='ID=arch'
fedora='ID=fedora'

expect_success "Ubuntu installs base packages and enables unattended-upgrades" \
  HAS_APT=1 "TEST_OS_RELEASE=${ubuntu}"
if grep -q 'apt-get install -y --no-install-recommends ca-certificates curl gnupg jq nftables unattended-upgrades age' "${tmpdir}/output" \
  && grep -q 'systemctl enable --now unattended-upgrades.service' "${tmpdir}/output" \
  && grep -q 'Automatic-Reboot "false"' "${tmpdir}/etc/apt/apt.conf.d/52clawshell-auto-reboot"; then
  ok "Existing apt package and unattended-upgrades behavior preserved"
else
  bad "Existing apt behavior changed"
fi
expect_success "Ubuntu provisions missing Docker" HAS_APT=1 MISSING_COMMAND=docker \
  "TEST_OS_RELEASE=${ubuntu}"
if ! grep -q 'apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' "${tmpdir}/output"; then
  bad "Missing Docker must be installed on apt hosts"
fi
if ! grep -q 'https://download.docker.com/linux/ubuntu/gpg' "${tmpdir}/output" \
  || ! grep -q '/linux/ubuntu noble stable' "${tmpdir}/etc/apt/sources.list.d/docker.list"; then
  bad "Ubuntu must use the correct Docker repository and codename"
fi
expect_success "Debian provisions missing Docker" HAS_APT=1 MISSING_COMMAND=docker \
  "TEST_OS_RELEASE=${debian}"
if ! grep -q '/linux/debian bookworm stable' "${tmpdir}/etc/apt/sources.list.d/docker.list"; then
  bad "Debian must use its own Docker repository"
fi
expect_success "Ubuntu derivative uses upstream codename" HAS_APT=1 MISSING_COMMAND=docker \
  TEST_OS_RELEASE=$'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_CODENAME=wilma\nUBUNTU_CODENAME=noble'
if ! grep -q '/linux/ubuntu noble stable' "${tmpdir}/etc/apt/sources.list.d/docker.list"; then
  bad "Ubuntu derivative must use upstream repository and codename"
fi
expect_success "Ubuntu repairs missing Compose without replacing Docker" HAS_APT=1 \
  COMPOSE_STATUS=1 "TEST_OS_RELEASE=${ubuntu}"
if ! grep -q 'apt-get install -y docker-compose-plugin' "${tmpdir}/output" \
  || grep -q 'docker-ce-cli' "${tmpdir}/output"; then
  bad "Compose repair must preserve an existing Docker installation"
fi
expect_success "Apt host provisions missing NVIDIA toolkit" HAS_APT=1 \
  MODEL_PROVIDER=local-gpu MISSING_COMMAND=nvidia-ctk "TEST_OS_RELEASE=${ubuntu}"
if ! grep -q 'nvidia-ctk runtime configure --runtime=docker' "${tmpdir}/output"; then
  bad "NVIDIA Docker runtime must be configured on apt hosts"
fi
expect_failure "Apt installation errors remain fatal" "apt-get update -y" \
  HAS_APT=1 PACKAGE_STATUS=1 "TEST_OS_RELEASE=${ubuntu}"

for arch_id in arch cachyos manjaro; do
  expect_success "${arch_id} automatically installs Docker and Compose with pacman" \
    HAS_PACMAN=1 MISSING_COMMAND=docker COMPOSE_STATUS=1 \
    "TEST_OS_RELEASE=ID=${arch_id}"$'\nID_LIKE=arch'
  if ! grep -q 'pacman -S --needed --noconfirm ca-certificates curl gnupg jq nftables age openssl docker docker-compose' "${tmpdir}/output" \
    || grep -qE 'INFO (apt-get|dnf) |pacman -Sy' "${tmpdir}/output"; then
    bad "Arch must use native packages without database-only refresh"
  fi
done
expect_success "Arch installs and configures NVIDIA toolkit" HAS_PACMAN=1 \
  MODEL_PROVIDER=local-gpu MISSING_COMMAND=nvidia-ctk "TEST_OS_RELEASE=${arch}"
if ! grep -q 'pacman -S --needed --noconfirm nvidia-container-toolkit' "${tmpdir}/output" \
  || ! grep -q 'nvidia-ctk runtime configure --runtime=docker' "${tmpdir}/output"; then
  bad "Arch must install and configure its native NVIDIA toolkit"
fi
expect_failure "Arch package failures include upgrade guidance" "pacman -Syu" \
  HAS_PACMAN=1 PACKAGE_STATUS=1 "TEST_OS_RELEASE=${arch}"

expect_success "Fedora installs Docker and Compose from the official RPM repository" \
  HAS_DNF=1 MISSING_COMMAND=docker COMPOSE_STATUS=1 "TEST_OS_RELEASE=${fedora}"
if ! grep -q 'https://download.docker.com/linux/fedora/docker-ce.repo' "${tmpdir}/output" \
  || ! grep -q 'dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' "${tmpdir}/output" \
  || grep -qE 'INFO (apt-get|pacman) ' "${tmpdir}/output"; then
  bad "Fedora must use dnf and the Fedora Docker repository"
fi
expect_success "Fedora repairs Compose without replacing installed Docker" \
  HAS_DNF=1 COMPOSE_STATUS=1 "TEST_OS_RELEASE=${fedora}"
if ! grep -q 'dnf install -y docker-compose-plugin' "${tmpdir}/output" \
  || grep -q 'docker-ce-cli' "${tmpdir}/output"; then
  bad "Fedora Compose repair must preserve Docker"
fi
expect_success "Fedora preserves existing Docker and Compose" HAS_DNF=1 \
  "TEST_OS_RELEASE=${fedora}"
if grep -q 'download.docker.com' "${tmpdir}/output"; then
  bad "Fedora must not add a Docker repository when Docker and Compose already work"
fi
expect_success "Fedora installs and configures NVIDIA toolkit" HAS_DNF=1 \
  MODEL_PROVIDER=local-gpu MISSING_COMMAND=nvidia-ctk "TEST_OS_RELEASE=${fedora}"
if ! grep -q 'stable/rpm/nvidia-container-toolkit.repo' "${tmpdir}/output" \
  || ! grep -q 'dnf install -y nvidia-container-toolkit' "${tmpdir}/output" \
  || ! grep -q 'nvidia-ctk runtime configure --runtime=docker' "${tmpdir}/output"; then
  bad "Fedora must install the RPM NVIDIA toolkit and configure Docker"
fi
expect_failure "Fedora package errors remain fatal" "dnf install" HAS_DNF=1 \
  PACKAGE_STATUS=1 "TEST_OS_RELEASE=${fedora}"
expect_success "RHEL-like host must not use Fedora repository" HAS_DNF=1 \
  TEST_OS_RELEASE=$'ID=rocky\nID_LIKE="rhel fedora"'
if grep -qE 'INFO dnf |download.docker.com' "${tmpdir}/output"; then
  bad "RHEL-like host must remain on the manual path"
fi
expect_failure "Detected Arch without pacman stops clearly" "pacman is missing" \
  "TEST_OS_RELEASE=${arch}"
expect_failure "Detected Ubuntu without apt stops clearly" "apt-get is missing" \
  "TEST_OS_RELEASE=${ubuntu}"
expect_failure "Detected Fedora without dnf stops clearly" "dnf is missing" \
  "TEST_OS_RELEASE=${fedora}"
expect_success "Arch AMD host does not install NVIDIA toolkit" HAS_PACMAN=1 \
  MODEL_PROVIDER=local-gpu LOCAL_LLM_BACKEND=amd-rocm MISSING_COMMAND=nvidia-ctk \
  "TEST_OS_RELEASE=${arch}"
if grep -qE 'nvidia-container-toolkit|nvidia-ctk runtime' "${tmpdir}/output"; then
  bad "AMD backend must not install or configure NVIDIA toolkit"
fi
expect_success "Fedora can disable the unattended-upgrades warning" HAS_DNF=1 \
  ENABLE_UNATTENDED_UPGRADES=false "TEST_OS_RELEASE=${fedora}"
if grep -q 'Skipping apt-specific unattended-upgrades' "${tmpdir}/output"; then
  bad "Disabled unattended-upgrades must not emit a skip warning"
fi
expect_failure "Failed post-install dependency check stops clearly" \
  "Missing dependency after package installation: docker" HAS_PACMAN=1 \
  MISSING_COMMAND=docker INSTALL_REPAIRS=0 "TEST_OS_RELEASE=${arch}"
expect_failure "Failed post-install Compose check stops clearly" \
  "Docker Compose plugin is missing or not working after package installation" \
  HAS_PACMAN=1 COMPOSE_STATUS=1 INSTALL_REPAIRS=0 "TEST_OS_RELEASE=${arch}"
expect_failure "NVIDIA Docker restart errors remain fatal" "systemctl restart docker" \
  HAS_PACMAN=1 MODEL_PROVIDER=local-gpu MISSING_COMMAND=nvidia-ctk \
  SYSTEMCTL_STATUS=1 "TEST_OS_RELEASE=${arch}"

exit "${FAIL}"
