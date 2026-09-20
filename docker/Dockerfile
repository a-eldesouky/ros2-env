# ROS 2 Jazzy image: Husarion's simulation, plus the tools to build against it.
#
# Fallback path. The native install (../install.sh) is the primary environment
# and is authoritative for grading; this image exists for machines that will not
# take a native install. README.md in this directory says why it is built this
# way.
#
# One apt layer on top of Husarion's published simulation image. The rosbot
# stack is NOT rebuilt from source: that costs 25 to 45 minutes against 3 to 6,
# and is less reproducible rather than more, because a source build tracks a
# branch and rosdep follows the archive.
#
# Build it with: docker compose build

# The upstream tag floats on purpose. Freezing happens at our layer: we build
# once, push a fixed tag, and pull that. If Husarion ever remove this
# tag, replace it with a dated stable one such as jazzy-0.18.8-20260303.
FROM husarion/rosbot-gazebo:jazzy

# desktop-full, not desktop, because the native path installs desktop-full and
# the difference is the perception and simulation variants. A package that
# exists on one path only is the worst kind of bug to receive by email.
ARG ROS_DISTRO=jazzy
ARG DEBIAN_FRONTEND=noninteractive

# The upstream image ends with `apt-get remove -y ros-dev-tools`, so the
# published image has no colcon and cannot build a package. ros-dev-tools below
# puts it back, which is the whole point of Sessions 7 onward.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ros-${ROS_DISTRO}-desktop-full \
      ros-${ROS_DISTRO}-navigation2 \
      ros-${ROS_DISTRO}-nav2-bringup \
      ros-${ROS_DISTRO}-nav2-map-server \
      ros-${ROS_DISTRO}-slam-toolbox \
      ros-${ROS_DISTRO}-ros-gz \
      ros-${ROS_DISTRO}-teleop-twist-keyboard \
      ros-${ROS_DISTRO}-demo-nodes-cpp \
      ros-${ROS_DISTRO}-rqt-graph \
      ros-${ROS_DISTRO}-rqt-common-plugins \
      ros-${ROS_DISTRO}-tf2-tools \
      ros-${ROS_DISTRO}-xacro \
      ros-dev-tools \
      build-essential \
      cmake \
      gdb \
      clang-format \
      doxygen \
      graphviz \
      git \
      nano \
      vim \
      less \
      sudo \
      gosu \
      x11-apps \
    && rm -rf /var/lib/apt/lists/*

# Non-root user. Bind mounts pass UIDs through untranslated, so running as root
# leaves root-owned files on the host. UID 1000 is baked, and the entrypoint remaps it when the
# host user is not 1000, which is what makes this work on lab machines with
# LDAP or a secondary account.
ARG USERNAME=ros
ARG USER_UID=1000
ARG USER_GID=1000

RUN set -eux; \
    # The base image may already own UID or GID 1000 under another name.
    if getent group "${USER_GID}" >/dev/null; then \
      existing_group="$(getent group "${USER_GID}" | cut -d: -f1)"; \
      groupmod -n "${USERNAME}" "${existing_group}"; \
    else \
      groupadd -g "${USER_GID}" "${USERNAME}"; \
    fi; \
    if getent passwd "${USER_UID}" >/dev/null; then \
      existing_user="$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
      usermod -l "${USERNAME}" -d "/home/${USERNAME}" -m "${existing_user}"; \
    else \
      useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash "${USERNAME}"; \
    fi; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

# The three source lines stay visible and commented rather than hidden. What
# each one does is worth knowing, so burying them helps nobody.
RUN set -eux; \
    home="/home/${USERNAME}"; \
    { \
      echo ''; \
      echo '# >>> ros2-env, ROS 2 jazzy >>>'; \
      echo '# 1. the ROS 2 installation itself'; \
      echo "source /opt/ros/${ROS_DISTRO}/setup.bash"; \
      echo '# 2. the Husarion simulation, built into the image'; \
      echo '[ -f /ros2_ws/install/setup.bash ] && source /ros2_ws/install/setup.bash'; \
      echo '# 3. your own workspace, which only exists after you build it'; \
      echo '[ -f /workspace/install/setup.bash ] && source /workspace/install/setup.bash'; \
      echo '# <<< ros2-env, ROS 2 jazzy <<<'; \
    } >> "${home}/.bashrc"; \
    chown "${USER_UID}:${USER_GID}" "${home}/.bashrc"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENV CONTAINER_USER=${USERNAME}
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
