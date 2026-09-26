#!/usr/bin/env bash
#
# Bare Ubuntu 24.04 to a working ROS 2 Jazzy environment and a built workspace.
#
# Usage:
#   ./install.sh                  normal run, logs to ~/.ros2-env/logs
#   ./install.sh --domain-id N    set the ROS_DOMAIN_ID written to ~/.bashrc
#   ./install.sh --verify-only    check an existing install, change nothing
#   ./install.sh --skip-verify    install without the final smoke test
#   ./install.sh --no-log         do not write a log file
#
# Run it again if it fails. Every command here is safe to repeat: apt skips what
# is installed, the clone pulls instead of cloning, and colcon builds only what
# changed. There is no resume state to get wrong.
#
# Expected versions live in pins.env, which env_check.sh reads as well.
#
# Do not run this with sudo. It refuses to run as root.

set -Eeuo pipefail

if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 )); then
  printf 'error this script needs bash 4 or newer. Run it as: bash install.sh\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PINS_FILE="${SCRIPT_DIR}/pins.env"
if [[ ! -f "${PINS_FILE}" ]]; then
  printf 'error pins.env not found next to this script (%s)\n' "${SCRIPT_DIR}" >&2
  printf 'Clone the whole ros2-env repository rather than copying install.sh alone.\n' >&2
  exit 1
fi
# shellcheck source=pins.env
source "${PINS_FILE}"

readonly ROS="${EXPECT_ROS_DISTRO}"
readonly WORKSPACE="${EXPECT_WORKSPACE}"
readonly STATE_DIR="${HOME}/.ros2-env"
readonly LOG_DIR="${STATE_DIR}/logs"
readonly REPOS_LOCK="${STATE_DIR}/workspace.repos.lock"
readonly ENV_CHECK="${SCRIPT_DIR}/env_check.sh"
readonly BRIDGE_PATCH="${SCRIPT_DIR}/patch_component_bridges.py"
readonly MARKER="# >>> ros2-env, ROS 2 jazzy >>>"
readonly MARKER_END="# <<< ros2-env, ROS 2 jazzy <<<"
# Written by older versions of this script. Removed on every run, so a rename
# cannot leave two blocks sourcing ROS twice with different domain ids.
readonly LEGACY_MARKER="# >>> robotics course, ROS 2 jazzy >>>"
readonly LEGACY_MARKER_END="# <<< robotics course, ROS 2 jazzy <<<"

ROS_DOMAIN_ID_VALUE="${ROS2_DOMAIN_ID:-0}"
LOG_FILE=""
CURRENT_STEP="startup"
# Set when the component bridge patch cannot be applied. Checked at the end,
# where --skip-verify cannot hide it.
BRIDGE_PATCH_FAILED=0

# ---------------------------------------------------------------- output

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi
readonly C_RESET C_BOLD C_RED C_GREEN C_YELLOW C_BLUE

info()   { printf '%s\n' "${C_BLUE}::${C_RESET} $*"; }
ok()     { printf '%s\n' "${C_GREEN}ok${C_RESET} $*"; }
warn()   { printf '%s\n' "${C_YELLOW}warning${C_RESET} $*" >&2; }
fail()   { printf '%s\n' "${C_RED}error${C_RESET} $*" >&2; }
banner() { CURRENT_STEP="$*"; printf '\n%s\n' "${C_BOLD}$*${C_RESET}"; }

on_error() {
  local code=$?
  printf '\n'
  fail "failed during: ${CURRENT_STEP}"
  fail "exit code ${code}"
  printf '\n%s\n' "Run ./install.sh again. It picks up where it stopped."
  if [[ -n "${LOG_FILE}" ]]; then
    printf '\n%s\n%s\n' "This run was logged to:" "    ${LOG_FILE}"
    printf '\n%s\n' "If it fails twice, send that log to a bug report."
  fi
  exit "${code}"
}
trap on_error ERR

# ---------------------------------------------------------------- helpers

# ROS and colcon setup scripts read variables they do not define, which trips
# set -u in whatever shell sources them.
ros_source() {
  set +u
  # shellcheck source=/dev/null
  source "$1"
  set -u
}

apt_install()      { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }

# ROS metapackages keep their recommends: dropping them removes rviz and rqt
# plugins that are not pulled in as hard dependencies.
apt_install_full() { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }

pkg_installed() {
  local status
  status="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
  [[ "${status}" == *"ok installed"* ]]
}

avail_gb() {
  local value
  value="$(df --output=avail -BG "$1" 2>/dev/null | tail -1 | tr -dc '0-9')"
  printf '%s' "${value:-0}"
}

mem_total_gb() {
  local kb
  kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  (( kb > 0 )) || { printf '0'; return; }
  printf '%s' $(( ( kb + 524288 ) / 1024 / 1024 ))
}

# colcon and cmake both fan out. On an 8 GB machine unbounded parallelism gets
# the build OOM killed, and you see a compiler crash rather than a memory
# error.
build_jobs() {
  local cpus jobs
  cpus="$(nproc 2>/dev/null || echo 2)"
  jobs=$(( $(mem_total_gb) / 4 ))
  (( jobs < 1 )) && jobs=1
  (( jobs > cpus )) && jobs="${cpus}"
  (( jobs > 8 )) && jobs=8
  printf '%s' "${jobs}"
}

# ---------------------------------------------------------------- guards

guard_not_root() {
  [[ "${EUID}" -ne 0 ]] && return 0
  fail "do not run this script as root or with sudo."
  printf '\n%s\n' "It builds a ROS 2 workspace in your home directory. As root, ${WORKSPACE}"
  printf '%s\n\n' "would end up owned by root and you could not edit your own code."
  printf '%s\n\n' "Run it as your normal user:    ./install.sh"
  printf '%s\n' "It asks for your password once and uses sudo only where needed."
  exit 1
}

guard_ubuntu() {
  if [[ ! -r /etc/os-release ]]; then
    fail "cannot read /etc/os-release, so this is not a supported system."
    exit 1
  fi
  local id version pretty
  id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"

  if [[ "${id}" == "ubuntu" && "${version}" == "${EXPECT_UBUNTU_VERSION}" ]]; then
    ok "Ubuntu ${EXPECT_UBUNTU_VERSION} detected"
    return 0
  fi

  fail "this needs Ubuntu ${EXPECT_UBUNTU_VERSION} LTS."
  printf '\n%s\n\n' "Detected: ${pretty}"
  if [[ "${id}" == "ubuntu" && "${version}" == "22.04" ]]; then
    printf '%s\n' "ROS 2 Jazzy publishes packages for Ubuntu 24.04 (noble) only. There is"
    printf '%s\n\n' "no 22.04 build, and this is not a flag the script can pass."
  fi
  printf '%s\n%s\n' "Install Ubuntu ${EXPECT_UBUNTU_VERSION} LTS, then run this script again:" \
                    "    https://releases.ubuntu.com/noble/"
  exit 1
}

guard_architecture() {
  local arch
  arch="$(dpkg --print-architecture)"
  case "${arch}" in
    amd64|arm64) ok "architecture ${arch}" ;;
    *) fail "ROS 2 Jazzy has no Ubuntu packages for architecture ${arch}."; exit 1 ;;
  esac
}

acquire_sudo() {
  info "asking for your password once, up front"
  sudo -v || { fail "sudo authentication failed."; exit 1; }
  # Keeps the sudo timestamp alive so no prompt appears mid-install.
  while true; do
    sudo -n true 2>/dev/null || true
    sleep 50
    kill -0 "$$" 2>/dev/null || exit
  done &
  local keepalive=$!
  # shellcheck disable=SC2064
  trap "kill ${keepalive} 2>/dev/null || true" EXIT
  ok "sudo ready"
}

# ---------------------------------------------------------------- preflight
#
# Warnings only. None of these stop the install: a 6 GB machine builds the
# workspace slowly rather than not at all.

preflight() {
  banner "Preflight"

  local ram
  ram="$(mem_total_gb)"
  if (( ram == 0 )); then
    warn "could not read total RAM from /proc/meminfo"
  elif (( ram < MIN_RAM_GB )); then
    warn "${ram} GB RAM, ${MIN_RAM_GB} GB recommended. Gazebo and Nav2 may be slow."
  else
    ok "${ram} GB RAM"
  fi

  local home_gb
  home_gb="$(avail_gb "${HOME}")"
  if (( home_gb < MIN_DISK_GB )); then
    warn "${home_gb} GB free on ${HOME}, ${MIN_DISK_GB} GB recommended."
  else
    ok "${home_gb} GB free on ${HOME}"
  fi

  # apt stages every .deb under /var/cache/apt/archives before unpacking it, and
  # the ROS metapackage is roughly 4 GB of them. Where /var is its own partition
  # this runs out long before $HOME does, and apt reports it as a bare "no space
  # left on device" in the middle of a download. It has already stopped one
  # install and one release upgrade on the test host.
  local var_gb
  var_gb="$(avail_gb /var)"
  if (( var_gb < MIN_VAR_GB )); then
    warn "${var_gb} GB free on /var, ${MIN_VAR_GB} GB recommended."
    warn "apt stages every package there before unpacking it."
    warn "Free some with: sudo apt-get clean && sudo journalctl --vacuum-size=200M"
  else
    ok "${var_gb} GB free on /var"
  fi

  # /dev/tcp rather than ping or curl, neither of which is guaranteed present
  # yet. All four hosts are needed later, so a proxy that allows only the Ubuntu
  # mirror is caught here rather than halfway through.
  local host unreachable=0
  for host in archive.ubuntu.com:80 packages.ros.org:443 github.com:443 api.github.com:443; do
    timeout 5 bash -c "exec 3<>/dev/tcp/${host%%:*}/${host##*:}" 2>/dev/null \
      || { warn "cannot reach ${host}"; unreachable=$((unreachable + 1)); }
  done
  if (( unreachable == 0 )); then
    ok "network reachable"
  else
    warn "${unreachable} required host(s) unreachable. Fix your proxy or captive portal first."
  fi

  # A second ROS distro makes the order of source lines decide which one a
  # shell gets, which is a hard failure to diagnose later.
  local other
  for other in /opt/ros/*; do
    [[ -d "${other}" && "$(basename "${other}")" != "${ROS}" ]] \
      && warn "another ROS distro at ${other}. This setup assumes ${ROS} only."
  done

  [[ -n "${WSL_DISTRO_NAME:-}" ]] && warn "running under WSL, which is untested here. Gazebo graphics may not work."
  [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]] \
    && warn "no graphical display detected. RViz and Gazebo need a desktop session."
  return 0
}

# ---------------------------------------------------------------- install

install_apt_base() {
  banner "Base tools and the universe repository"
  sudo apt-get update
  apt_install software-properties-common curl gnupg2 lsb-release ca-certificates locales
  sudo add-apt-repository -y universe
  sudo apt-get update

  sudo locale-gen en_US en_US.UTF-8
  # LANG only. Setting LC_ALL system wide overrides every per-category setting a
  # machine may have, which is more than this needs.
  sudo update-locale LANG=en_US.UTF-8
  export LANG=en_US.UTF-8

  # Plain C++ toolchain and docs tools, useful before ROS 2 is involved.
  apt_install build-essential cmake git wget doxygen graphviz clang-format gdb
  ok "base tools and C++ toolchain"
}

install_ros_apt_source() {
  banner "ROS 2 apt source"
  if pkg_installed ros2-apt-source; then
    ok "ros2-apt-source already registered"
    return 0
  fi

  # ROS ships its repository configuration as a package now, so key rotations
  # arrive as ordinary package updates instead of a raw keyring going stale.
  local version codename deb tmp
  version="$(curl -fsSL --max-time 20 \
    https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest 2>/dev/null \
    | grep -F '"tag_name"' | awk -F'"' '{print $4}' || true)"

  # That call is unauthenticated and gets rate limited from a university NAT.
  if [[ -z "${version}" ]]; then
    warn "could not read the latest ros-apt-source release from GitHub"
    warn "using the known good version ${ROS_APT_SOURCE_FALLBACK} from pins.env"
    version="${ROS_APT_SOURCE_FALLBACK}"
  fi
  info "ros-apt-source version ${version}"

  codename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"
  deb="https://github.com/ros-infrastructure/ros-apt-source/releases/download/${version}/ros2-apt-source_${version}.${codename}_all.deb"
  tmp="$(mktemp /tmp/ros2-apt-source.XXXXXX.deb)"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp}'" RETURN

  curl -fsSL -o "${tmp}" "${deb}" || {
    fail "could not download ${deb}"
    fail "check that version against the ros-apt-source releases page."
    return 1
  }
  # apt-get, not dpkg -i, so dependencies resolve instead of leaving dpkg half
  # configured.
  apt_install_full "${tmp}"
  sudo apt-get update
  ok "packages.ros.org registered"
}

install_ros() {
  banner "ROS 2 ${ROS^}, Nav2 and Gazebo"

  if pkg_installed "ros-${ROS}-desktop-full" || pkg_installed "ros-${ROS}-desktop"; then
    ok "ROS 2 ${ROS^} already installed"
  elif apt-cache show "ros-${ROS}-desktop-full" >/dev/null 2>&1; then
    info "installing ros-${ROS}-desktop-full, this is the long part"
    apt_install_full "ros-${ROS}-desktop-full"
  else
    warn "ros-${ROS}-desktop-full not found, falling back to desktop plus variants"
    apt_install_full "ros-${ROS}-desktop" "ros-${ROS}-perception" "ros-${ROS}-simulation"
  fi

  apt_install_full \
    ros-dev-tools python3-colcon-common-extensions python3-rosdep \
    python3-vcstool python3-argcomplete \
    "ros-${ROS}-navigation2" "ros-${ROS}-nav2-bringup" "ros-${ROS}-nav2-map-server" \
    "ros-${ROS}-slam-toolbox" "ros-${ROS}-ros-gz" \
    "ros-${ROS}-teleop-twist-keyboard" "ros-${ROS}-demo-nodes-cpp" \
    "ros-${ROS}-rqt-graph" "ros-${ROS}-rqt-common-plugins" \
    "ros-${ROS}-tf2-tools" "ros-${ROS}-xacro"
  ok "ROS 2, Nav2, slam_toolbox and the build tooling"

  # ros-gz is supposed to bring Gazebo Harmonic through its vendor packages. It
  # does not bring the gz binary on noble, so this fires on every machine tested
  # so far, which is why packages.osrfoundation.org is a required host.
  if ! command -v gz >/dev/null 2>&1; then
    warn "gz binary not present after ros-gz, adding the OSRF repository"
    sudo curl -fsSL -o /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg \
      https://packages.osrfoundation.org/gazebo.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] http://packages.osrfoundation.org/gazebo/ubuntu-stable $(. /etc/os-release && echo "${UBUNTU_CODENAME}") main" \
      | sudo tee /etc/apt/sources.list.d/gazebo-stable.list > /dev/null
    sudo apt-get update
    apt_install_full gz-harmonic
  fi
  ok "Gazebo $(gz sim --version 2>/dev/null | head -1 || echo Harmonic)"

  if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
    sudo rosdep init
  fi
  rosdep update --rosdistro "${ROS}"
  ok "rosdep database"
}

# Keeps the packages named in WORKSPACE_EXCLUDE_PACKAGES out of the build.
# Husarion's own answer is to delete them; this writes ignore files instead, so
# the hardware sources stay readable even though they are not built.
apply_exclusions() {
  local rel
  for rel in ${WORKSPACE_EXCLUDE_PACKAGES}; do
    [[ -d "${WORKSPACE}/src/${rel}" ]] || continue
    touch "${WORKSPACE}/src/${rel}/AMENT_IGNORE" "${WORKSPACE}/src/${rel}/COLCON_IGNORE"
    ok "excluded ${rel}, see WORKSPACE_EXCLUDE_PACKAGES in pins.env"
  done
}

# Repairs the component bridge table upstream left behind when they renamed the
# component types. Without it the simulation starts clean and publishes no
# /scan, which then fails SLAM and Nav2. The whole explanation, and the table
# itself, are in pins.env above COMPONENT_BRIDGE_ALIASES.
#
# Applied to the vcs import checkout, not to rosbot_ros: that one is pulled
# --ff-only on every run, and a patched file there would turn every later run
# into a refused fast forward. husarion_components_description arrives through
# vcs import --skip-existing, which never touches it again.
patch_component_bridges() {
  local target="${WORKSPACE}/src/husarion_components_description/launch/gz_components.launch.py"
  # Defaulted, so an older pins.env without the table is a skip rather than an
  # unbound variable under set -u.
  local aliases="${COMPONENT_BRIDGE_ALIASES:-}"

  if [[ -z "${aliases// /}" ]]; then
    info "COMPONENT_BRIDGE_ALIASES is empty, leaving upstream's bridge table alone"
    return 0
  fi
  if [[ ! -f "${BRIDGE_PATCH}" ]]; then
    warn "patch_component_bridges.py not found next to install.sh"
    warn "the simulation will build and run, but /scan will have no publisher"
    return 0
  fi
  if [[ ! -f "${target}" ]]; then
    warn "gz_components.launch.py not found, skipping the component bridge patch"
    warn "expected ${target}"
    return 0
  fi

  local status=0
  python3 "${BRIDGE_PATCH}" "${target}" "${aliases}" || status=$?
  case "${status}" in
    0) ok "component bridges patched, /scan and /oak/* will reach ROS 2" ;;
    2) ok "component bridges already patched" ;;
    3) ok "component bridges need no patch, upstream carries the names now" ;;
    *)
      BRIDGE_PATCH_FAILED=1
      warn "could not patch gz_components.launch.py, it is not shaped as expected"
      warn "the workspace will build, and the simulation will publish no /scan"
      ;;
  esac
}

install_sources() {
  banner "Workspace sources"
  mkdir -p "${WORKSPACE}/src"

  # One clone, tracking the branch, which is what Husarion's own setup
  # instructions do. Everything else the simulation needs arrives through the
  # manifest inside it.
  local dest="${WORKSPACE}/src/rosbot_ros"
  if [[ -d "${dest}/.git" ]]; then
    # Fast forward only. Local edits to these sources get a refusal rather than
    # a silent reset that eats them.
    git -C "${dest}" pull --quiet --ff-only origin "${ROSBOT_BRANCH}" || {
      warn "rosbot_ros could not fast forward, leaving it alone"
      warn "move or delete ${dest} and re-run if you want the current upstream."
    }
  else
    git clone --quiet --branch "${ROSBOT_BRANCH}" "${ROSBOT_REPO}" "${dest}" || {
      fail "could not clone ${ROSBOT_BRANCH} from ${ROSBOT_REPO}"
      fail "check the branch in pins.env and that github.com is reachable."
      return 1
    }
  fi
  ok "rosbot_ros on ${ROSBOT_BRANCH}, at $(git -C "${dest}" rev-parse --short=8 HEAD)"

  # Anything of your own goes in ${WORKSPACE}/src alongside it. This script only
  # ever adds the upstream sources, so a package you put there is left alone by
  # every later run.
}

install_deps() (
  banner "Workspace dependencies"
  ros_source "/opt/ros/${ROS}/setup.bash"
  cd "${WORKSPACE}"

  # The simulation manifest, not the hardware one: rosbot_hardware.repos pulls
  # the micro-ROS agent and the ROSbot firmware, neither of which a simulation
  # setup uses. Its path has moved between upstream releases, so it is located rather
  # than assumed, and a miss is fatal because continuing produces a build
  # failure several minutes later with no obvious cause.
  local manifest
  manifest="$(find src/rosbot_ros -name 'rosbot_simulation.repos' -print -quit 2>/dev/null || true)"
  if [[ -z "${manifest}" ]]; then
    fail "rosbot_simulation.repos not found under src/rosbot_ros on ${ROSBOT_BRANCH}"
    fail "upstream may have moved it to a layout this script does not know."
    exit 1
  fi

  info "importing simulation repos listed by ${manifest}"
  vcs import --skip-existing src < "${manifest}"
  apply_exclusions

  # Nothing here is pinned by this repository: the clone tracks a branch and the
  # manifest moves when upstream moves it. This records the exact commits this
  # machine got, which is what makes one workspace comparable to another when
  # something breaks.
  mkdir -p "${STATE_DIR}"
  vcs export --exact src > "${REPOS_LOCK}" 2>/dev/null \
    || vcs export src > "${REPOS_LOCK}" 2>/dev/null \
    || warn "could not record source commits in ${REPOS_LOCK}"

  # rosdep fails the whole workspace over one unresolvable key. Its own message
  # names the keys, so it is repeated here with the file that decides what to do
  # about them, rather than leaving you to read rosdep's output cold.
  local output unresolved
  if ! output="$(rosdep install --from-paths src --ignore-src -y \
      --rosdistro "${ROS}" --skip-keys "${ROSDEP_SKIP_KEYS}" 2>&1)"; then
    printf '%s\n' "${output}"
    unresolved="$(printf '%s\n' "${output}" \
      | sed -n 's/.*Cannot locate rosdep definition for \[\([^]]*\)\].*/\1/p' \
      | sort -u | tr '\n' ' ')"
    if [[ -n "${unresolved}" ]]; then
      fail "rosdep could not resolve: ${unresolved}"
      fail "If you do not need them, add them to ROSDEP_SKIP_KEYS in"
      fail "pins.env, and the package that declares them to WORKSPACE_EXCLUDE_PACKAGES."
    fi
    exit 1
  fi
  printf '%s\n' "${output}"
  ok "dependencies resolved"
)

build_workspace() (
  banner "Workspace build"
  ros_source "/opt/ros/${ROS}/setup.bash"
  cd "${WORKSPACE}"
  local jobs
  jobs="$(build_jobs)"
  info "building with ${jobs} parallel job(s), this takes several minutes"
  # --base-paths src, to match the rosdep call above. Without it colcon scans the
  # whole workspace directory and will happily try to build anything else you
  # left there, whose dependencies were never resolved.
  MAKEFLAGS="-j${jobs}" colcon build \
    --base-paths src \
    --symlink-install \
    --parallel-workers "${jobs}" \
    --cmake-args -DCMAKE_BUILD_TYPE=Release
  ok "workspace built"
)

# ROS 2 itself is sourced automatically. The workspace is not: you source it per
# shell, on purpose, so an unsourced shell behaves the way ROS expects instead
# of silently half working.
#
# The block goes at the TOP of ~/.bashrc, above Ubuntu's interactivity guard:
#
#     case $- in *i*) ;; *) return;; esac
#
# Everything below that guard is skipped for every non-interactive shell: every
# `ssh machine 'command'`, every script, every `bash -lc`. Appended at the end,
# the block would give a working ROS 2 in the terminal and an unset
# ROS_DOMAIN_ID everywhere else, so a node started from a script joins domain 0
# with SUBNET discovery. The terminal looks correct while it happens.
setup_bashrc() {
  banner "Shell setup"
  touch "${HOME}/.bashrc"

  # Any block from a previous run is replaced rather than duplicated, wherever
  # in the file it sits, under the current name or the older one.
  if grep -qF "${MARKER}" "${HOME}/.bashrc" 2>/dev/null; then
    info "replacing the existing ros2-env block in ~/.bashrc"
    sed -i "/${MARKER}/,/${MARKER_END}/d" "${HOME}/.bashrc"
  fi
  if grep -qF "${LEGACY_MARKER}" "${HOME}/.bashrc" 2>/dev/null; then
    info "removing a block left by an older version of this script"
    sed -i "/${LEGACY_MARKER}/,/${LEGACY_MARKER_END}/d" "${HOME}/.bashrc"
  fi

  local block rest
  block="$(mktemp)"; rest="$(mktemp)"
  {
    printf '%s\n' "${MARKER}"
    printf '%s\n' "# Above the interactivity guard on purpose: scripts, cron jobs and"
    printf '%s\n' "# 'ssh machine command' never reach the rest of this file."
    printf '%s\n' "source /opt/ros/${ROS}/setup.bash"
    printf '%s\n' "# Keeps your ROS 2 graph on this machine only. Do not remove:"
    printf '%s\n' "export ROS_AUTOMATIC_DISCOVERY_RANGE=${EXPECT_DISCOVERY_RANGE}"
    printf '%s\n' "# Your DDS domain. Anything 0 to 101; machines sharing one see each other:"
    printf '%s\n' "export ROS_DOMAIN_ID=${ROS_DOMAIN_ID_VALUE}"
    printf '%s\n' "# The workspace is sourced per shell, not here:"
    printf '%s\n' "#   source ${WORKSPACE}/install/setup.bash"
    printf '%s\n' "${MARKER_END}"
    printf '\n'
  } > "${block}"

  cat "${block}" "${HOME}/.bashrc" > "${rest}" && mv "${rest}" "${HOME}/.bashrc"
  rm -f "${block}" "${rest}"
  ok "ROS 2 block added at the top of ~/.bashrc, ROS_DOMAIN_ID=${ROS_DOMAIN_ID_VALUE}"

  [[ "${SHELL:-}" != *bash ]] \
    && warn "your login shell is ${SHELL:-unknown}. Copy the block into its startup file."
  return 0
}

# What the archive happened to hold on install day. pins.env fixes the distro,
# not the package versions, so this is the record that makes a broken machine
# comparable to a working one.
write_manifest() {
  local out="${STATE_DIR}/manifest-$(date -u +%Y%m%dT%H%M%SZ).txt"
  mkdir -p "${STATE_DIR}"
  {
    printf 'Recorded %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '\n== system ==\n'
    lsb_release -ds 2>/dev/null || true
    printf 'arch %s\n' "$(dpkg --print-architecture)"
    printf '\n== toolchain ==\n'
    g++ --version 2>/dev/null | head -1 || true
    cmake --version 2>/dev/null | head -1 || true
    gz sim --version 2>/dev/null | head -1 || true
    printf '\n== ros packages ==\n'
    dpkg-query -W -f='${Package} ${Version}\n' "ros-${ROS}-*" 2>/dev/null | sort || true
    printf '\n== workspace sources ==\n'
    cat "${REPOS_LOCK}" 2>/dev/null || true
  } > "${out}" 2>/dev/null || true
  ok "recorded installed versions in ${out}"
}

# ---------------------------------------------------------------- verification

verify() {
  banner "Verification"
  local failures=0

  # Versions and presence are env_check.sh's job. It is the same script you run
  # on its own and paste when asking for help, so duplicating its checks here is
  # how the two drift apart.
  if [[ -x "${ENV_CHECK}" ]]; then
    ROS_AUTOMATIC_DISCOVERY_RANGE="${EXPECT_DISCOVERY_RANGE}" \
    ROS_DOMAIN_ID="${ROS_DOMAIN_ID_VALUE}" \
    "${ENV_CHECK}" --stage full || failures=$((failures + 1))
  else
    fail "env_check.sh not found or not executable at ${ENV_CHECK}"
    failures=$((failures + 1))
  fi

  banner "Runtime checks"
  ros_source "/opt/ros/${ROS}/setup.bash"

  # Without these a talker on a neighbouring machine can satisfy the discovery
  # check and hide a broken install.
  export ROS_AUTOMATIC_DISCOVERY_RANGE="${EXPECT_DISCOVERY_RANGE}"
  export ROS_DOMAIN_ID="${ROS_DOMAIN_ID_VALUE}"

  info "checking topic discovery with a demo talker"
  if ! ros2 pkg prefix demo_nodes_cpp >/dev/null 2>&1; then
    fail "demo_nodes_cpp is not installed, cannot test discovery"
    failures=$((failures + 1))
  else
    ros2 daemon stop >/dev/null 2>&1 || true
    ros2 run demo_nodes_cpp talker >/dev/null 2>&1 &
    local pid=$! waited=0 seen=0 topics
    # Discovery is slower on a cold VM than on a warm laptop, so this polls.
    while (( waited < 30 )); do
      topics="$(ros2 topic list 2>/dev/null || true)"
      [[ $'\n'"${topics}"$'\n' == *$'\n/chatter\n'* ]] && { seen=1; break; }
      sleep 2
      waited=$((waited + 2))
    done
    if (( seen )); then
      ok "/chatter visible after ${waited}s, publish and discovery work"
    else
      fail "/chatter not found after ${waited}s, ROS 2 discovery is not working"
      failures=$((failures + 1))
    fi
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    # ros2 run forks the node, so the parent dying is not enough.
    pkill -f 'demo_nodes_cpp.*talker' 2>/dev/null || true
  fi

  info "checking Gazebo headless"
  if ! command -v gz >/dev/null 2>&1; then
    fail "gz binary not found"
    failures=$((failures + 1))
  elif timeout 120 gz sim -s -r -v 1 --iterations 50 empty.sdf >/dev/null 2>&1; then
    ok "Gazebo ran 50 headless iterations"
  else
    fail "Gazebo failed to run headless"
    failures=$((failures + 1))
  fi

  printf '\n'
  if (( failures == 0 )); then
    printf '%s\n' "${C_GREEN}${C_BOLD}All checks passed.${C_RESET}"
    return 0
  fi
  printf '%s\n' "${C_RED}${C_BOLD}${failures} check group(s) failed.${C_RESET}"
  return 1
}

# ---------------------------------------------------------------- main

usage() {
  cat <<'USAGE'
Bare Ubuntu 24.04 to a working ROS 2 Jazzy environment and a built workspace.

Usage:
  ./install.sh                 normal run, logs to ~/.ros2-env/logs
  ./install.sh --domain-id N   set the ROS_DOMAIN_ID written to ~/.bashrc
  ./install.sh --verify-only   check an existing install, change nothing
  ./install.sh --skip-verify   install without the final smoke test
  ./install.sh --no-log        do not write a log file

If it fails, run it again. Everything here is safe to repeat.

Checking an install without touching it:
  ./env_check.sh               versions and presence, pass or fail per line
  ./env_check.sh --stage pre   host tooling only, before ROS 2 is installed

Do not run this with sudo. It refuses to run as root.
USAGE
}

start_logging() {
  mkdir -p "${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/install-$(date -u +%Y%m%dT%H%M%SZ).log"
  # Everything on screen lands in the log too, colour stripped so the file can
  # be pasted into an issue.
  exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' > "${LOG_FILE}")) 2>&1
  info "logging this run to ${LOG_FILE}"
}

main() {
  local skip_verify=0 verify_only=0 no_log=0

  while (( $# )); do
    case "$1" in
      --skip-verify) skip_verify=1 ;;
      --verify-only) verify_only=1 ;;
      --no-log)      no_log=1 ;;
      --domain-id)
        shift
        [[ "${1:-}" =~ ^[0-9]+$ ]] || { fail "--domain-id needs a number, for example --domain-id 7"; exit 1; }
        ROS_DOMAIN_ID_VALUE="$1"
        ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown option: $1"; usage; exit 1 ;;
    esac
    shift
  done

  guard_not_root
  (( no_log )) || start_logging

  if (( verify_only )); then
    verify && exit 0
    printf '\n%s\n' "Run ./install.sh to repair the install, then check again."
    exit 1
  fi

  banner "ROS 2 ${ROS^} environment setup"
  printf '%s\n' "Target: Ubuntu ${EXPECT_UBUNTU_VERSION} with ROS 2 ${ROS^}"
  printf '%s\n' "Workspace: ${WORKSPACE}"

  guard_ubuntu
  guard_architecture
  preflight
  acquire_sudo

  install_apt_base
  install_ros_apt_source
  install_ros
  install_sources
  install_deps
  # After the import that puts the file there, before the build that installs
  # it. Called from here rather than from install_deps, because that one runs
  # in a subshell and nothing it sets would reach the check at the end.
  patch_component_bridges
  build_workspace
  setup_bashrc
  write_manifest

  if (( skip_verify )); then
    banner "Skipping verification as requested"
  elif ! verify; then
    printf '\n%s\n' "Everything installed, but the checks above did not all pass."
    [[ -n "${LOG_FILE}" ]] && printf '%s\n' "Send ${LOG_FILE} to a bug report."
    exit 1
  fi

  # Outside the block above on purpose. A workspace with no /scan is a broken
  # environment, and --skip-verify is not a reason to call it finished.
  if (( BRIDGE_PATCH_FAILED )); then
    printf '\n%s\n' "Everything installed, but the component bridge patch did not apply,"
    printf '%s\n' "so the simulation will publish no /scan. See COMPONENT_BRIDGE_ALIASES"
    printf '%s\n' "in pins.env, which says what changed upstream and what to do about it."
    [[ -n "${LOG_FILE}" ]] && printf '%s\n' "Send ${LOG_FILE} to a bug report."
    exit 1
  fi

  banner "Setup complete"
  printf '%s\n\n' "Open a new terminal, then:"
  printf '%s\n' "    ros2 --help"
  printf '%s\n\n' "    source ${WORKSPACE}/install/setup.bash"
  printf '%s\n' "Your ROS_DOMAIN_ID is ${ROS_DOMAIN_ID_VALUE}. Change it in ~/.bashrc if you"
  printf '%s\n\n' "need a different one."
  printf '%s\n\n' "To prove the setup, run this in the new terminal and paste the output:"
  printf '%s\n\n' "    ${ENV_CHECK}"
}

main "$@"
