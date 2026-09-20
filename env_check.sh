#!/usr/bin/env bash
#
# Environment check: prints what this machine has, next to what this setup
# expects, and says pass or fail per line.
#
# Usage:
#   ./env_check.sh                     full check, use this after install.sh
#   ./env_check.sh --stage pre         host tooling only, no ROS 2 required
#   ./env_check.sh --stage full        everything, ROS 2 and the workspace
#   ./env_check.sh --no-color          plain text even on a terminal
#   ./env_check.sh --help
#
# Exit codes:
#   0  every check passed
#   1  something is present but does not match the expected value
#   2  something required is not installed at all
#
# Paste the whole output when asking for help. It is the diagnostic.

# No -e. Every line below is a probe that is allowed to fail; the table is the
# report, not the exit path.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 )); then
  printf 'error this script needs bash 4 or newer. Run it as: bash env_check.sh\n' >&2
  exit 2
fi

# ---------------------------------------------------------------- pins

PINS_FILE="${SCRIPT_DIR}/pins.env"
if [[ ! -f "${PINS_FILE}" ]]; then
  printf 'error pins.env not found next to this script (%s)\n' "${SCRIPT_DIR}" >&2
  printf 'This script reads the expected values from pins.env. Clone the whole\n' >&2
  printf 'ros2-env repository rather than copying env_check.sh on its own.\n' >&2
  exit 2
fi
# shellcheck source=pins.env
source "${PINS_FILE}"

# ---------------------------------------------------------------- path
#
# Native and Docker are the same environment, checked by the same script. The two
# differ in exactly two places: where the workspace is, and whether the Husarion
# sources are a checkout on disk or already inside the image. Everything else in
# this file is identical, which is why there is one script and not two.

if [[ -f /.dockerenv ]] || grep -qa 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
  INSTALL_PATH="docker"
else
  INSTALL_PATH="host"
fi
readonly INSTALL_PATH

# ---------------------------------------------------------------- output

STAGE="full"
USE_COLOR=1
[[ -t 1 ]] || USE_COLOR=0

C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''

set_colors() {
  if (( USE_COLOR )); then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m';  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''
  fi
}

# Fixed widths so the table still lines up when it is pasted into a chat window
# or an issue, where the font is often not monospaced.
readonly W_CHECK=30 W_FOUND=28 W_EXPECT=32

PASS_COUNT=0
FAIL_COUNT=0
MISSING_COUNT=0
NEEDS_NEW_SHELL=0

row() {
  local name="$1" found="$2" expected="$3" result="$4" color=''
  case "${result}" in
    PASS)    color="${C_GREEN}";  PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL)    color="${C_RED}";    FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    MISSING) color="${C_RED}";    MISSING_COUNT=$((MISSING_COUNT + 1)) ;;
    WARN)    color="${C_YELLOW}" ;;
    *)       color='' ;;
  esac
  # Padded, never truncated. A long value pushes RESULT right on that one line,
  # which is better than a table that hides the value you need to read.
  printf '%-*s %-*s %-*s %s%s%s\n' \
    "${W_CHECK}"  "${name}" \
    "${W_FOUND}"  "${found}" \
    "${W_EXPECT}" "${expected}" \
    "${color}" "${result}" "${C_RESET}"
}

header_row() {
  printf '%s' "${C_BOLD}"
  printf '%-*s %-*s %-*s %s' \
    "${W_CHECK}" "CHECK" "${W_FOUND}" "FOUND" "${W_EXPECT}" "EXPECTED" "RESULT"
  printf '%s\n' "${C_RESET}"
}

section() { printf '\n%s%s%s\n' "${C_BOLD}" "$1" "${C_RESET}"; }

# ---------------------------------------------------------------- assertions
#
# Four widths, because different things deserve different strictness. An exact
# patch version fails every time the archive moves; presence alone lets a wrong
# distro through.

assert_exact() {
  local name="$1" found="$2" expected="$3"
  if [[ -z "${found}" ]]; then
    row "${name}" "not found" "${expected}" "MISSING"
  elif [[ "${found}" == "${expected}" ]]; then
    row "${name}" "${found}" "${expected}" "PASS"
  else
    row "${name}" "${found}" "${expected}" "FAIL"
  fi
}

# Compares the first N dot separated fields, so 3.28.3 satisfies 3.28.
assert_version() {
  local name="$1" found="$2" expected="$3" fields="$4"
  if [[ -z "${found}" ]]; then
    row "${name}" "not found" "${expected}.x" "MISSING"
    return
  fi
  local found_cut expected_cut
  found_cut="$(printf '%s' "${found}" | cut -d. -f"1-${fields}")"
  expected_cut="$(printf '%s' "${expected}" | cut -d. -f"1-${fields}")"
  if [[ "${found_cut}" == "${expected_cut}" ]]; then
    row "${name}" "${found}" "${expected}.x" "PASS"
  else
    row "${name}" "${found}" "${expected}.x" "FAIL"
  fi
}

assert_present() {
  local name="$1" found="$2" note="${3:-present}"
  if [[ -n "${found}" ]]; then
    row "${name}" "${found}" "${note}" "PASS"
  else
    row "${name}" "not found" "${note}" "MISSING"
  fi
}

assert_path() {
  local name="$1" path="$2"
  if [[ -e "${path}" ]]; then
    row "${name}" "${path}" "exists" "PASS"
  else
    row "${name}" "not found" "${path}" "MISSING"
  fi
}

# ---------------------------------------------------------------- probes

probe_os() {
  local name version
  # shellcheck source=/dev/null
  name="$(. /etc/os-release 2>/dev/null && printf '%s' "${NAME:-}")"
  version="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-}")"
  printf '%s' "${name:+${name} }${version}"
}

probe_gxx()   { command -v g++   >/dev/null 2>&1 && g++ -dumpversion 2>/dev/null; }
probe_cmake() { command -v cmake >/dev/null 2>&1 && cmake --version 2>/dev/null | head -1 | awk '{print $3}'; }

probe_gz() {
  command -v gz >/dev/null 2>&1 || return 0
  # "Gazebo Sim, version 8.9.0" on Harmonic, but the wording has changed before,
  # so take the first version shaped token rather than a fixed field.
  gz sim --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

probe_pkg_version() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null | head -1
}

# Captured, not piped. Under `set -o pipefail`, grep -q exiting at its first
# match kills the writer with SIGPIPE and the pipeline reports 141 even though
# the match succeeded.
pkg_installed() {
  local status
  status="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
  [[ "${status}" == *"ok installed"* ]]
}

# ROS and colcon setup scripts read variables they do not define, which trips
# set -u in whatever shell sources them.
ros_source() {
  set +u
  # shellcheck source=/dev/null
  source "$1"
  local rc=$?
  set -u
  return "${rc}"
}

# ---------------------------------------------------------------- stages

# RAM and disk are advisory. A 6 GB machine builds the workspace, slowly, and
# failing the check over it would be a lie about whether the machine works.
resource_row() {
  local name="$1" found="$2" minimum="$3"
  if [[ -n "${found}" ]] && (( found >= minimum )); then
    row "${name}" "${found} GB" "${minimum} GB or more" "PASS"
  else
    row "${name}" "${found:-unknown} GB" "${minimum} GB or more" "WARN"
  fi
}

check_host() {
  section "Host"
  assert_exact "os" "$(probe_os)" "Ubuntu ${EXPECT_UBUNTU_VERSION}"

  # amd64 and arm64 both have Jazzy packages, and install.sh accepts both. The
  # container image is built for amd64 only, which is a Docker question rather
  # than a host one.
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "${arch}" in
    amd64|arm64|x86_64|aarch64) row "architecture" "${arch}" "amd64 or arm64" "PASS" ;;
    *)                          row "architecture" "${arch}" "amd64 or arm64" "FAIL" ;;
  esac

  resource_row "ram" \
    "$(awk '/MemTotal/ {printf "%d", ($2 + 524288) / 1024 / 1024}' /proc/meminfo 2>/dev/null)" \
    "${MIN_RAM_GB}"
  resource_row "disk free on \$HOME" \
    "$(df --output=avail -BG "${HOME}" 2>/dev/null | tail -1 | tr -dc '0-9')" 10
  # /var is often its own partition, and apt stages every .deb under
  # /var/cache/apt/archives before unpacking. It runs out before $HOME does.
  resource_row "disk free on /var" \
    "$(df --output=avail -BG /var 2>/dev/null | tail -1 | tr -dc '0-9')" "${MIN_VAR_GB}"
}

check_toolchain() {
  section "Toolchain"
  assert_version "g++"    "$(probe_gxx)"    "${EXPECT_GXX_MAJOR}" 1
  assert_version "cmake"  "$(probe_cmake)"  "${EXPECT_CMAKE_MAJOR_MINOR}" 2
  assert_present "git"    "$(command -v git >/dev/null 2>&1 && git --version | awk '{print $3}')"
  assert_present "python3" "$(command -v python3 >/dev/null 2>&1 && python3 -V 2>&1 | awk '{print $2}')"
}

check_host_tools() {
  section "Developer tooling"
  local t path
  for t in doxygen gdb clang-format; do
    path="$(command -v "${t}" 2>/dev/null)"
    assert_present "${t}" "${path}"
  done
}

check_ros() {
  section "ROS 2"

  assert_path "ros setup" "${EXPECT_ROS_SETUP}"

  # Sourcing here means a shell that predates the install still gets a usable
  # answer for everything except the two variables below.
  #
  # The condition is the ros2 CLI, not ROS_DISTRO. An image can set ROS_DISTRO
  # while PATH still has no ros2, because it sources setup.bash from a shell
  # startup file that a non-interactive `docker exec` never reads.
  if ! command -v ros2 >/dev/null 2>&1 && [[ -f "${EXPECT_ROS_SETUP}" ]]; then
    ros_source "${EXPECT_ROS_SETUP}" || true
    # On the Docker path the rosbot stack is built into the image, not into the
    # bind-mounted workspace, so its overlay has to be sourced as well or every
    # rosbot and Gazebo row reports missing on a working image.
    if [[ "${INSTALL_PATH}" == "docker" && -f "${EXPECT_IMAGE_OVERLAY}" ]]; then
      ros_source "${EXPECT_IMAGE_OVERLAY}" || true
    fi
    NEEDS_NEW_SHELL=1
  fi

  assert_exact "ROS_DISTRO" "${ROS_DISTRO:-}" "${EXPECT_ROS_DISTRO}"

  local meta=''
  if pkg_installed "${EXPECT_ROS_METAPACKAGE}"; then
    meta="${EXPECT_ROS_METAPACKAGE}"
  elif pkg_installed "${EXPECT_ROS_METAPACKAGE_ALT}"; then
    meta="${EXPECT_ROS_METAPACKAGE_ALT}"
  fi
  if [[ "${meta}" == "${EXPECT_ROS_METAPACKAGE}" ]]; then
    row "ros metapackage" "${meta}" "${EXPECT_ROS_METAPACKAGE}" "PASS"
  elif [[ -n "${meta}" ]]; then
    # The fallback set is a working install. Both paths target desktop-full, so
    # the difference is worth saying out loud without failing anyone over it.
    row "ros metapackage" "${meta}" "${EXPECT_ROS_METAPACKAGE}" "WARN"
  else
    row "ros metapackage" "not found" "${EXPECT_ROS_METAPACKAGE}" "MISSING"
  fi

  local ros2_pkgs=''
  if command -v ros2 >/dev/null 2>&1; then
    ros2_pkgs="$(ros2 pkg list 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [[ -n "${ros2_pkgs}" && "${ros2_pkgs}" != "0" ]]; then
    row "ros2 CLI" "${ros2_pkgs} packages" "responds" "PASS"
  elif command -v ros2 >/dev/null 2>&1; then
    row "ros2 CLI" "no packages listed" "responds" "FAIL"
  else
    row "ros2 CLI" "not found" "responds" "MISSING"
  fi

  assert_version "gazebo (gz sim)" "$(probe_gz)" "${EXPECT_GZ_MAJOR}" 1

  local p
  for p in nav2_bringup slam_toolbox; do
    if command -v ros2 >/dev/null 2>&1 && ros2 pkg prefix "${p}" >/dev/null 2>&1; then
      row "${p}" "resolvable" "present" "PASS"
    else
      row "${p}" "not found" "present" "MISSING"
    fi
  done
}

check_build_tools() {
  section "Build tooling"
  assert_present "colcon" "$(probe_pkg_version python3-colcon-common-extensions)" \
    "python3-colcon-common-extensions"
  # Noble ships rosdep as python3-rosdep2; the upstream ROS repositories ship
  # python3-rosdep. Either one works.
  local rosdep_version
  rosdep_version="$(probe_pkg_version python3-rosdep2)"
  [[ -n "${rosdep_version}" ]] || rosdep_version="$(probe_pkg_version python3-rosdep)"
  assert_present "rosdep" "${rosdep_version}"
  assert_present "vcstool" "$(command -v vcs >/dev/null 2>&1 && printf 'vcs')"

  # rosdep update writes the cache under $HOME; rosdep init writes the source
  # list under /etc. Either one missing means rosdep resolves nothing.
  if [[ -d "${HOME}/.ros/rosdep" ]]; then
    row "rosdep database" "${HOME}/.ros/rosdep" "initialised" "PASS"
  elif [[ -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
    if [[ "${INSTALL_PATH}" == "docker" ]]; then
      # entrypoint.sh remaps the container user to the host UID at start, so a
      # cache baked at build time would belong to the wrong user. Run
      # `rosdep update` once, when you add dependencies of your own.
      row "rosdep database" "sources list only" "run rosdep update when you need it" "WARN"
    else
      row "rosdep database" "sources list only" "initialised, updated" "FAIL"
    fi
  else
    row "rosdep database" "not initialised" "initialised" "MISSING"
  fi
}

check_workspace() {
  section "Workspace"

  assert_path "workspace" "${EXPECT_WORKSPACE}"

  # On the native path install.sh builds this workspace, so a missing overlay
  # means the install did not finish. In a container the same directory is the
  # bind mount from the host and is empty until you build something in it, which
  # is not an install failure.
  if [[ -f "${EXPECT_WORKSPACE}/install/setup.bash" ]]; then
    row "workspace overlay" "${EXPECT_WORKSPACE}/install/setup.bash" "exists" "PASS"
  elif [[ "${INSTALL_PATH}" == "docker" ]]; then
    row "workspace overlay" "not built yet" "built once you build in it" "WARN"
  else
    row "workspace overlay" "not found" "${EXPECT_WORKSPACE}/install/setup.bash" "MISSING"
  fi

  # Recorded, not asserted. rosbot_ros tracks a branch and the rest arrives
  # through its manifest, so there is no commit here that stays right. The
  # commits each machine got are in ~/.ros2-env/workspace.repos.lock,
  # which is the file to diff between a working machine and a broken one.
  local repo sha_found
  for repo in rosbot_ros husarion_gz_worlds; do
    if [[ "${INSTALL_PATH}" == "docker" ]]; then
      # Not a git checkout inside the image, so there is no commit to report.
      row "${repo}" "from the image" "recorded, not pinned" "WARN"
      continue
    fi
    if [[ ! -d "${EXPECT_HUSARION_SRC}/${repo}" ]]; then
      row "${repo}" "not found" "${EXPECT_HUSARION_SRC}/${repo}" "MISSING"
      continue
    fi
    sha_found="$(git -C "${EXPECT_HUSARION_SRC}/${repo}" rev-parse --short=8 HEAD 2>/dev/null)"
    row "${repo}" "${sha_found:-present, not a git checkout}" "recorded, not pinned" "PASS"
  done

  # Sourcing the overlay is what proves the build produced something usable,
  # which a directory listing does not. On the Docker path the rosbot stack comes
  # from the image overlay, sourced earlier, and not from the bind mount.
  if [[ -f "${EXPECT_WORKSPACE}/install/setup.bash" ]] && command -v ros2 >/dev/null 2>&1; then
    ros_source "${EXPECT_WORKSPACE}/install/setup.bash" || true
  fi
  if command -v ros2 >/dev/null 2>&1; then
    local rosbot_count packages
    packages="$(ros2 pkg list 2>/dev/null || true)"
    rosbot_count="$(printf '%s\n' "${packages}" | grep -c '^rosbot' || true)"
    if [[ "${rosbot_count}" -gt 0 ]]; then
      row "rosbot packages" "${rosbot_count} available" "1 or more" "PASS"
    else
      row "rosbot packages" "none found" "1 or more" "FAIL"
    fi
  else
    row "rosbot packages" "ros2 not available" "1 or more" "MISSING"
  fi

}

check_shell_env() {
  section "Shell environment"

  assert_exact "ROS_AUTOMATIC_DISCOVERY_RANGE" \
    "${ROS_AUTOMATIC_DISCOVERY_RANGE:-}" "${EXPECT_DISCOVERY_RANGE}"

  local domain="${ROS_DOMAIN_ID:-}"
  if [[ -z "${domain}" ]]; then
    row "ROS_DOMAIN_ID" "not set" "set, numeric" "FAIL"
  elif [[ "${domain}" =~ ^[0-9]+$ ]]; then
    row "ROS_DOMAIN_ID" "${domain}" "set, numeric" "PASS"
  else
    row "ROS_DOMAIN_ID" "${domain}" "set, numeric" "FAIL"
  fi

  # Both variables come from the ~/.bashrc block, not from setup.bash, so they
  # are the two things missed by checking in the same terminal that ran the
  # installer.
  if [[ -z "${ROS_AUTOMATIC_DISCOVERY_RANGE:-}" || -z "${ROS_DOMAIN_ID:-}" ]]; then
    NEEDS_NEW_SHELL=1
  fi
}

# ---------------------------------------------------------------- main

usage() {
  cat <<'USAGE'
Environment check: what this machine has, next to what this setup expects.

Usage:
  ./env_check.sh                 full check, use this after install.sh
  ./env_check.sh --stage pre     host tooling only, before ROS 2 is installed
  ./env_check.sh --stage full    everything, ROS 2 and the workspace
  ./env_check.sh --no-color      plain text even on a terminal
  ./env_check.sh --help

Exit codes:
  0  every check passed
  1  something is present but does not match the expected value
  2  something required is not installed at all

Paste the whole output when you ask for help with your setup.
USAGE
}

main() {
  while (( $# )); do
    case "$1" in
      --stage)
        shift
        case "${1:-}" in
          pre|full) STAGE="$1" ;;
          *) printf 'error --stage takes pre or full\n' >&2; exit 2 ;;
        esac
        ;;
      --stage=pre)  STAGE="pre" ;;
      --stage=full) STAGE="full" ;;
      --no-color)   USE_COLOR=0 ;;
      -h|--help)    usage; exit 0 ;;
      *) printf 'error unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
  set_colors

  printf '%s%s, environment check%s\n' "${C_BOLD}" "${ENV_NAME}" "${C_RESET}"
  printf 'stage %s   path %s   pins %s   host %s   user %s   %s\n' \
    "${STAGE}" "${INSTALL_PATH}" "${PINS_REVISION}" \
    "$(hostname 2>/dev/null || printf 'unknown')" \
    "$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")" \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '\n'
  header_row

  check_host
  check_toolchain

  if [[ "${STAGE}" == "full" ]]; then
    check_host_tools
    check_ros
    check_build_tools
    check_workspace
    check_shell_env
  fi

  local total=$((PASS_COUNT + FAIL_COUNT + MISSING_COUNT))
  printf '\n'
  printf '%s%d of %d checks passed. %d failed, %d missing.%s\n' \
    "${C_BOLD}" "${PASS_COUNT}" "${total}" "${FAIL_COUNT}" "${MISSING_COUNT}" "${C_RESET}"

  if (( MISSING_COUNT > 0 )); then
    printf '\n%s\n' "Something is not installed. Run ./install.sh, then check again."
    if (( NEEDS_NEW_SHELL )); then
      printf '%s\n' "If you just ran the installer, open a new terminal first."
    fi
    exit 2
  fi
  if (( FAIL_COUNT > 0 )); then
    printf '\n%s\n' "Everything is installed, but something does not match the expected version."
    if (( NEEDS_NEW_SHELL )); then
      printf '%s\n' "If you just ran the installer, open a new terminal and check again."
    fi
    printf '%s\n' "Paste this output when asking for help."
    exit 1
  fi
  if [[ "${STAGE}" == "pre" ]]; then
    printf '\n%s\n' "Host tooling is ready. Run ./install.sh to add ROS 2."
  fi
  exit 0
}

main "$@"
