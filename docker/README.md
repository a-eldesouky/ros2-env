# Docker path

The fallback. Use it if `install.sh` will not complete on your machine, or if
your machine is not Ubuntu 24.04.

> CI publishes the image to GitHub Container Registry on every push to `main`
> that passes its checks, so the pull below needs no account and no login.

Linux hosts only. Gazebo and RViz reach your screen through the X11 socket, and
there is no macOS or Windows equivalent that renders fast enough to work in.

## Host setup, once

```bash
sudo apt-get install -y docker.io docker-compose-v2
```

```bash
sudo usermod -aG docker $USER
```

**Then log out and log back in.** Not a new terminal, a full log out. This is the
step people skip before reporting Docker as broken.

Check it worked:

```bash
docker run --rm hello-world
```

If that needs `sudo`, you did not log out.

## Get the image

```bash
docker pull ghcr.io/a-eldesouky/ros2-env:jazzy
```

Two tags are published: `jazzy` moves with every build, and `jazzy-<date>` is
fixed, so pin the dated one if you need the same image next month. Set
`ROS2_IMAGE` in `.env` to whichever you pull.

Building it yourself instead takes 3 to 6 minutes and needs no login:

```bash
cd docker && docker compose build
```

## Set it up

```bash
cd ros2-env/docker
cp .env.example .env
```

Edit `.env`. Three values matter:

```bash
mkdir -p ~/ros2_ws_docker/src
id -u
id -g
```

* `WS_HOST`, the absolute path to `~/ros2_ws_docker`, spelled out.
* `HOST_UID` and `HOST_GID`, what the two `id` commands printed.
* `ROS_DOMAIN_ID`, any number 0 to 101. Machines sharing one see each other.

`~/ros2_ws_docker`, **not** `~/ros2_ws`. The native installer builds
`~/ros2_ws` with symlinks that only make sense outside a container. Point the
mount at it and the container will refuse to start, on purpose.

Let the container see your display:

```bash
xhost +local:docker
```

That lasts until you log out. If windows stop appearing after a reboot, this is
why.

## Run it

```bash
docker compose up -d
docker compose exec dev bash
```

Same two commands whether or not you have a GPU. Graphics are four variables in
`.env`, and the defaults are software rendering, which works on any machine:

```
DOCKER_RUNTIME=runc
LIBGL_ALWAYS_SOFTWARE=1
NVIDIA_VISIBLE_DEVICES=
NVIDIA_DRIVER_CAPABILITIES=
```

With an NVIDIA card and `nvidia-container-toolkit` installed on the host, set
them to `nvidia`, `0`, `all`, `all`. If the toolkit is not installed, `up`
fails with `unknown or invalid runtime name`, which is the only check there is.

On software rendering Gazebo runs at roughly 5 to 15 frames per second. It is
ugly and it is usable.

## Prove it works

```bash
docker compose exec --user ros dev /opt/ros2-env/env_check.sh
```

That runs the same `env_check.sh` the native path uses, inside the container:
the repository is bind mounted read only at `/opt/ros2-env`, so it is the very
same file, and the two paths cannot disagree about what a working environment
is. Paste its whole output when you ask for help.

`--user ros` matters. `docker compose exec` comes in as root, and root has
`HOME=/root`, so the workspace and rosdep rows would be checked against paths
nothing actually uses.

Two rows read differently in here, and both are expected:

* `rosbot_ros` and `husarion_gz_worlds` say **from the image**. The container's
  Husarion sources come from the published image rather than a pinned checkout.
* the workspace is `/workspace`, not `~/ros2_ws`.

## Working in it

Your code lives in `~/ros2_ws_docker/src` on the host and appears at
`/workspace/src` in the container. Edit it with your normal editor on the host;
build it inside:

```bash
cd /workspace
colcon build --symlink-install
source install/setup.bash
```

The simulation runs in its own container and needs nothing from you:

```bash
docker compose logs -f sim
```

Stop everything:

```bash
docker compose down
```

## What survives, and what does not

| Thing | Survives a `down` and `up` |
|---|---|
| Anything under `~/ros2_ws_docker` | Yes, it is on the host |
| Packages you `apt install` inside the container | **No** |
| Shell history, dotfile edits inside the container | **No** |

If a package turns out to be needed later, add it to the apt list in
`../install.sh` and rebuild the image, rather than each person remembering a
command they typed once inside a container that gets recreated.

## Files here

| File | What it is |
|---|---|
| `Dockerfile` | one apt layer on Husarion's simulation image, plus the non-root user |
| `entrypoint.sh` | uid and gid remap, and the refusal to start on a natively built workspace |
| `compose.yaml` | the `sim` and `dev` services |
| `.env.example` | copy to `.env`, per machine |

## Why it is built this way

Husarion publish `husarion/rosbot-gazebo:jazzy`, and it cannot be used as it
is. Reading their `docker/Dockerfile.simulation` shows why: the base is
`ros-core`, so there is no rviz2, no rqt and no demo nodes, and the last layer
runs `apt-get remove -y ros-dev-tools`, so the published image has no colcon and
you could not build a package in it.

So this is one apt layer on top of theirs, adding `ros-jazzy-desktop-full`,
Nav2, slam_toolbox, `ros-dev-tools` and the Sessions 1 to 6 toolchain.
`desktop-full` rather than `desktop` because the native install uses
`desktop-full`, and a package that exists on one path only is the worst kind of
bug to debug by email.

Rebuilding the rosbot stack from source was rejected: 25 to 45 minutes per build
against 3 to 6, and less reproducible rather than more, since the workspace
clone tracks a branch and rosdep follows the archive. Running Husarion's own
multi-container pattern was rejected too. It is the vendor's intended shape, and
it multiplies what a beginner can break.

Three details that are easy to get wrong and are deliberate here:

* **`sim` has no bind mount over its workspace.** The upstream image was built
  with `--symlink-install`, so `/ros2_ws/install` links back into `/ros2_ws/src`.
  Mounting your code over that path breaks the launch files it ships.
* **The bind mount is `~/ros2_ws_docker`, not `~/ros2_ws`.** The native
  install builds that other directory with `--symlink-install` too, and those
  absolute symlinks do not resolve inside a container. `entrypoint.sh` refuses to
  start if you point it at one anyway.
* **UID 1000 is remapped at start, not baked.** Bind mounts pass UIDs through
  untranslated, so a fixed UID works on a normal desktop and fails on a lab
  machine with LDAP, which is harder to diagnose than failing everywhere.
