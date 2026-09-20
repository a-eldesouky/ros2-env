#!/usr/bin/env bash
#
# Container entrypoint.
#
# Two jobs, in this order:
#   1. refuse to start on a workspace that was built natively, loudly
#   2. make the container user match the host user, then drop privileges
#
# Everything here runs as root and nothing after `gosu` does.

set -Eeuo pipefail

readonly USERNAME="${CONTAINER_USER:-ros}"
readonly WORKSPACE="/workspace"

log()  { printf '%s\n' "$*"; }
fail() { printf 'error %s\n' "$*" >&2; }

# ---------------------------------------------------------------- 1. workspace
#
# The native install builds ~/ros2_ws with --symlink-install, so
# ~/ros2_ws/install is full of absolute symlinks into /home/<user>/ros2_ws.
# Those paths do not exist in here. Someone who tried the native install,
# failed, and fell back to Docker is exactly who this catches, and without the
# check they get an overlay that is silently, partially broken.
#
# The fix is a different host directory, ~/ros2_ws_docker, which is what the
# compose file binds. See README.md in this directory.
guard_native_workspace() {
  [[ -d "${WORKSPACE}/install" ]] || return 0

  local broken
  broken="$(find "${WORKSPACE}/install" -maxdepth 4 -xtype l -print -quit 2>/dev/null || true)"
  [[ -n "${broken}" ]] || return 0

  fail "the workspace mounted at ${WORKSPACE} was built somewhere else."
  fail ""
  fail "  ${broken}"
  fail ""
  fail "That is a dangling symlink, which means this install/ tree was produced"
  fail "by a colcon build with --symlink-install on the host, not in here."
  fail "Sourcing it would half work and fail later in a way nobody can debug."
  fail ""
  fail "Fix it on the host, not in the container:"
  fail ""
  fail "  1. Bind a separate directory. The compose file already does:"
  fail "       WS_HOST=\${HOME}/ros2_ws_docker"
  fail "     Check your .env if you changed it."
  fail ""
  fail "  2. Or, if this directory really is meant for Docker only, clear the"
  fail "     host build products and rebuild inside the container:"
  fail "       rm -rf ~/ros2_ws_docker/{build,install,log}"
  exit 1
}

# ---------------------------------------------------------------- 2. identity
remap_user() {
  local target_uid="${HOST_UID:-}" target_gid="${HOST_GID:-}"
  [[ -n "${target_uid}" && -n "${target_gid}" ]] || return 0

  local current_uid current_gid
  current_uid="$(id -u "${USERNAME}")"
  current_gid="$(id -g "${USERNAME}")"

  if [[ "${current_gid}" != "${target_gid}" ]]; then
    log "remapping ${USERNAME} gid ${current_gid} to ${target_gid}"
    groupmod -o -g "${target_gid}" "${USERNAME}"
  fi
  if [[ "${current_uid}" != "${target_uid}" ]]; then
    log "remapping ${USERNAME} uid ${current_uid} to ${target_uid}"
    usermod -o -u "${target_uid}" "${USERNAME}"
  fi

  # The home directory only. Chowning the bind mount would rewrite ownership of
  # your files on the host, which is the opposite of the point.
  chown -R "${target_uid}:${target_gid}" "/home/${USERNAME}"
}

main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    # Already unprivileged, which happens when compose sets `user:`. Nothing to
    # remap and nothing to drop.
    exec "$@"
  fi

  guard_native_workspace
  remap_user

  # The workspace is only created when it is missing. An existing one is left
  # exactly as it is, including its ownership.
  if [[ ! -d "${WORKSPACE}/src" ]]; then
    mkdir -p "${WORKSPACE}/src"
    chown "${HOST_UID:-1000}:${HOST_GID:-1000}" "${WORKSPACE}" "${WORKSPACE}/src" 2>/dev/null || true
  fi

  exec gosu "${USERNAME}" "$@"
}

main "$@"
