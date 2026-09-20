# ros2-env

One script takes a bare Ubuntu 24.04 machine to a working ROS 2 Jazzy
environment: ROS 2 desktop-full, Gazebo Harmonic, Nav2, slam_toolbox, and the
Husarion ROSbot simulation built into a workspace you can immediately work in.

One script, one check script, and a container if the native install will not
take. Everything it installs is upstream: ROS 2 from `packages.ros.org`, Gazebo
from OSRF, the ROSbot stack from Husarion's own `jazzy` branch. Nothing is
vendored and nothing is forked.

```bash
git clone https://github.com/a-eldesouky/ros2-env.git
cd ros2-env
./install.sh
```

Do not run it with `sudo`. It asks for your password once, uses `sudo` only
where it has to, and refuses to start as root. Budget 20 to 60 minutes, nearly
all of it ROS 2 downloading: a 12 core machine on a fast mirror finishes in 13,
and a laptop on shared campus wifi is the slow end.

## Contents

- [What you need](#what-you-need)
- [Install](#install)
- [Proving it works](#proving-it-works)
- [What it changes on your machine](#what-it-changes-on-your-machine)
- [Your workspace](#your-workspace)
- [The simulation](#the-simulation)
- [SLAM and navigation](#slam-and-navigation)
- [Troubleshooting](#troubleshooting)
- [What is pinned, and what is not](#what-is-pinned-and-what-is-not)
- [Layout](#layout)

## What you need

* Ubuntu 24.04 LTS, desktop, with a graphical session. ROS 2 Jazzy has no 22.04
  build, and Gazebo and RViz need a screen.
* 8 GB RAM, 16 GB is better.
* 30 GB free on `$HOME`, and 6 GB free on `/var` if it is a separate partition.
  apt stages about 4 GB of downloads there, and that is usually what runs out.
* Network access to `archive.ubuntu.com`, `packages.ros.org`, `github.com`,
  `api.github.com` and `packages.osrfoundation.org`.

**Not on Ubuntu 24.04?** Run it in a virtual machine and follow the native
install inside it, exactly as written. A VM is just a machine; there is no
separate image to download and no separate instructions. Give it 8 GB of RAM and
40 GB of disk, enable virtualisation in your firmware if the hypervisor
complains, and expect Gazebo to be slow. The other option is the container in
[docker/](docker/), which is Linux hosts only.

**WSL2 is not supported.** It can be made to work. Keeping it working is a
support burden this project does not take on.

## Install

### 1. Check the machine first

```bash
./env_check.sh --stage pre
```

That checks Ubuntu, g++, cmake, git and python3, and expects no ROS 2 yet.

### 2. Install

```bash
./install.sh
```

With an assigned DDS domain number:

```bash
./install.sh --domain-id 7
```

Safe to leave alone, and safe to interrupt. If it stops, run it again: every
command in it can be repeated, so a second run carries on from where the first
one stopped.

Installing over SSH with no `DISPLAY` works and warns that it found no
graphical display. That is correct: the install finishes, and Gazebo and RViz
need a desktop session when you come to use them.

| Flag | What it does |
|---|---|
| `--domain-id N` | Sets the `ROS_DOMAIN_ID` written to `~/.bashrc` |
| `--verify-only` | Runs the checks against an existing install, changes nothing |
| `--skip-verify` | Installs without the final smoke test |
| `--no-log` | Does not write a log file |
| `--help` | Prints this list |

### 3. Prove it

Open a **new** terminal, not a new tab in the shell that ran the installer, so
that `~/.bashrc` is read.

```bash
./env_check.sh
source ~/ros2_ws/install/setup.bash
ros2 launch rosbot_gazebo simulation.yaml robot_model:=rosbot
```

A Gazebo window with a ROSbot in it means you are done.

## Proving it works

```bash
./env_check.sh
```

It prints what your machine has next to what is expected, one line each, and
says `PASS`, `FAIL` or `MISSING`. Exit codes, for scripting: `0` everything
passed, `1` something is installed at the wrong version, `2` something is not
installed at all.

That output is the diagnostic. Paste it when you ask for help; a screenshot of a
working `ros2 --help` proves nothing.

## What it changes on your machine

* Installs ROS 2 Jazzy desktop-full, Gazebo Harmonic, Nav2, slam_toolbox, the
  build toolchain, doxygen, gdb and clang-format.
* Clones the Husarion ROSbot sources into `~/ros2_ws` and builds them.
* Adds a marked block at the **top** of `~/.bashrc`:

```bash
source /opt/ros/jazzy/setup.bash
export ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST
export ROS_DOMAIN_ID=0
```

Leave those two `ROS_*` lines alone. Without them every ROS 2 node on the same
network joins one graph, and in a lab that means twenty people discovering and
driving each other's robots.

The block goes above the interactivity guard in `~/.bashrc` on purpose.
Everything below that guard is skipped for non-interactive shells, so a block
appended at the end would leave scripts and `ssh machine 'command'` on the
default domain while your terminal looked fine.

Your workspace is **not** sourced automatically. Source it per session.

## Your workspace

```
~/ros2_ws/
├── src/          the only directory you edit
│   ├── rosbot_ros/            Husarion, upstream. Do not edit.
│   ├── husarion_gz_worlds/    Husarion, upstream. Do not edit.
│   └── <your packages>
├── build/        colcon's scratch space
├── install/      what a build produces, and what you source
└── log/          build logs, read them when a build fails
```

`install.sh` creates all of it. You never create `build`, `install` or `log`
yourself, and deleting them is safe: they are output, not source. On the Docker
path the same tree is at `/ros2_ws` in the container and `~/ros2_ws_docker`
on the host.

### Build it

```bash
cd ~/ros2_ws
colcon build --symlink-install
```

`--symlink-install` links files into `install/` instead of copying them, so
editing a launch file or a Python script takes effect without rebuilding. C++
still has to be rebuilt, because C++ has to be compiled.

Building one package rather than all of them, which you will want constantly:

```bash
colcon build --packages-select <package>
```

### Source it

```bash
source ~/ros2_ws/install/setup.bash
```

**In every terminal, every time.** It is kept out of `~/.bashrc` on purpose:
seeing what an unsourced shell does is worth learning early, and "it works in
that terminal but not this one" is a lesson better learned in week 7 than in
week 15.

If `ros2 run` says a package is not found, the overlay is not sourced in that
terminal. That is the whole diagnosis.

### When a build fails

Read the first error, not the last. colcon prints a summary at the end, and the
real message is usually hundreds of lines above it:

```bash
colcon build --packages-select <package> --event-handlers console_direct+
```

A build that fails in a package you did not touch usually means a stale
`install/`. Clearing it costs a rebuild and nothing else:

```bash
cd ~/ros2_ws && rm -rf build install log && colcon build --symlink-install
```

Never with `sudo`. A root-owned `build/` is a bad afternoon.

### What not to do

* Do not edit anything in `src/rosbot_ros` or `src/husarion_gz_worlds`. They are
  upstream checkouts the installer manages, and a later run updates them.
* Do not commit `build/`, `install/` or `log/`.
* Do not run `colcon` with `sudo`.

## The simulation

```bash
source ~/ros2_ws/install/setup.bash
ros2 launch rosbot_gazebo simulation.yaml robot_model:=rosbot
```

Headless, which is what you want on a machine without a GPU:

```bash
ros2 launch rosbot_gazebo simulation.yaml robot_model:=rosbot gz_headless_mode:=True
```

Upstream's argument names are easy to get wrong, and all four of these have
caused a failed launch:

| Argument | Note |
|---|---|
| `simulation.yaml` | a YAML frontend launch file. There is no `simulation.launch.py` |
| `robot_model` | **required**. It defaults to the `ROBOT_MODEL` environment variable, which is unset on a fresh machine, and the empty value fails upstream's own choice check before anything starts |
| `gz_headless_mode` | not `headless` |
| `True` / `False` | capitalised. Lowercase is rejected as an invalid choice |

### Topics

| Topic | Type | Direction |
|---|---|---|
| `/cmd_vel` | `geometry_msgs/msg/TwistStamped` | you publish |
| `/scan` | `sensor_msgs/msg/LaserScan` | you subscribe |
| `/odometry/filtered` | `nav_msgs/msg/Odometry` | you subscribe |
| `/tf`, `/tf_static` | `tf2_msgs/msg/TFMessage` | you subscribe |
| `/imu/data` | `sensor_msgs/msg/Imu` | you subscribe |
| `/joint_states` | `sensor_msgs/msg/JointState` | you subscribe |
| `/map` | `nav_msgs/msg/OccupancyGrid` | you subscribe, once SLAM or Nav2 runs |
| `/initialpose` | `geometry_msgs/msg/PoseWithCovarianceStamped` | you publish |
| `/goal_pose` | `geometry_msgs/msg/PoseStamped` | you publish |
| `/navigate_to_pose` | `nav2_msgs/action/NavigateToPose` | action, you call |

**`/cmd_vel` is `TwistStamped`, not `Twist`.** Every `cmd_vel` topic in the
graph is stamped: `/cmd_vel`, `/manual/cmd_vel` and `/autonomous/cmd_vel`, all
multiplexed by `twist_mux_controller` with the gamepad on the highest priority
input. Publishing `Twist` connects to nothing and raises no error, which is the
least debuggable failure you can hit here. By hand:

```bash
ros2 topic pub /cmd_vel geometry_msgs/msg/TwistStamped \
  '{twist: {linear: {x: 0.2}}}' --rate 10
```

The simulation publishes more than this: `/odometry/wheels` is wheel-only
odometry from before the EKF, `/oak/*` is the depth camera, and `/set_pose`
resets the EKF.

## SLAM and navigation

This repository ships no Nav2 configuration, because Husarion already publish
one that is kept current. Their
[`tutorial_pkg`](https://github.com/husarion/tutorial_pkg) carries
`config/navigation.yaml`, `config/slam.yaml`, `config/amcl.yaml`, a laser
filter, RViz layouts and example maps, and it is what their
[ROS 2 tutorial series](https://husarion.com/tutorials/ros2-tutorials/1-ros2-introduction/)
builds towards:

```bash
cd ~/ros2_ws/src
git clone -b ros2 https://github.com/husarion/tutorial_pkg.git
cd ~/ros2_ws && colcon build --symlink-install
```

Then, with the simulation already running in another terminal:

```bash
source ~/ros2_ws/install/setup.bash
ros2 launch tutorial_pkg navigation.launch.yaml use_sim_time:=true
```

Add `slam:=True` to map a world instead of localising against a saved one.

Two things are worth knowing before you clone it.

**`explore_lite` is not released for Jazzy.** `tutorial_pkg` declares it as a
dependency for its exploration tutorial, and `rosdep` fails the entire
workspace over one unresolvable key. `pins.env` already lists it in
`ROSDEP_SKIP_KEYS`, so an install run here resolves; if you run `rosdep` by hand,
pass `--skip-keys explore_lite`. Navigation and SLAM do not need it.

**The footprint is ROSbot XL by default.** `navigation.yaml` says so in a
comment at the top and gives the replacement for ROSbot 3 and 3 PRO. Change it
before wondering why the robot clips corners.

The `ros2` branch targets Jazzy, even though some tutorial pages still show
Humble Docker images: its plugin names use the `nav2_*::Class` form and it
configures `collision_monitor` and `docking_server`, both of which are Jazzy.
It also sets `enable_stamped_cmd_vel: true` throughout, which is required here,
because the ROSbot subscribes to `TwistStamped` and Nav2 publishes plain `Twist`
without it.

## Troubleshooting

### It refuses to start

| What it says | What to do |
|---|---|
| Refuses when run with `sudo` | Run it as yourself: `./install.sh` |
| Names Ubuntu 22.04 and stops | ROS 2 Jazzy has no 22.04 build, and this is not a flag it can pass. Install 24.04 |
| Names a system that is not Ubuntu | Ubuntu 24.04 in a VM, or the Docker path |
| Names your architecture | Jazzy has packages for amd64 and arm64 only |

### It fails partway through

**Run it again first.** apt skips what is installed, the clone pulls instead of
cloning, colcon rebuilds only what changed. A second run fixes most
interruptions. If it fails in the same place twice, the log is at
`~/.ros2-env/logs/install-<timestamp>.log`.

### Network

| What you see | What to do |
|---|---|
| `could not read the latest ros-apt-source release from GitHub` | Nothing. Shared networks look like one caller to GitHub; it falls back to a known good version |
| Preflight lists unreachable hosts, then apt or git fails | Proxy or captive portal. Fix the network and run again. This is the most common real failure |
| apt fails on `packages.ros.org` only | That mirror is mid-sync. Wait an hour |

### Warnings that are not errors

| Warning | What it costs you |
|---|---|
| Under 8 GB RAM | Fewer parallel build jobs, so it takes longer |
| Under 30 GB free on `$HOME` | It may fail later at the build |
| Under 6 GB free on `/var` | apt stages about 4 GB there. This one really does stop the install |
| No `DISPLAY`, or a Wayland session | RViz and Gazebo need a desktop session |
| Another ROS distro under `/opt/ros` | Two distros sourced in one shell is a bad afternoon |
| Login shell is not bash | Copy the `~/.bashrc` block into your own shell's startup file |

### After it finishes

| Symptom | Fix |
|---|---|
| `ros2: command not found` | The terminal predates the install. Open a new one |
| `env_check` says `ROS_DOMAIN_ID not set` | Same |
| `Package not found` | The overlay is not sourced: `source ~/ros2_ws/install/setup.bash` |
| Gazebo opens black, or at 2 fps | Software rendering. Expected without a GPU; use `gz_headless_mode:=True` plus RViz |
| Two robots in one simulation | You and someone else share a `ROS_DOMAIN_ID` |

### Bugs in this repository, not your machine

Send these rather than trying to fix them:

* `rosbot_simulation.repos not found under src/rosbot_ros on <branch>`
* `could not clone <branch> from <url>`

## What is pinned, and what is not

Ubuntu 24.04 and ROS 2 Jazzy are fixed, and the installer refuses anything else.
Nothing below them is pinned to a commit: `rosbot_ros` tracks its `jazzy` branch
and imports upstream's own manifest, which is what
[Husarion's setup instructions](https://husarion.com/tutorials/ros2-tutorials/1-ros2-introduction/)
do.

That means upstream can change what you get without anything here changing, so
every install records what it actually received:

```
~/.ros2-env/workspace.repos.lock      exact commit per repository
~/.ros2-env/manifest-<timestamp>.txt  apt package versions
```

Those two files are what make a broken machine comparable to a working one, and
`vcs import src < workspace.repos.lock` is how you put a machine back on a
configuration that worked. CI runs the whole install weekly for the same reason:
an upstream break should be a red build rather than a room full of people.

`pins.env` is the one place expected versions live, read by both scripts so they
cannot disagree. Do not edit it to make a check pass: a machine that passes
against edited pins has proved nothing.

## Layout

```
install.sh          the installer
env_check.sh        the environment check
pins.env            the expected versions, read by both scripts
docker/             the container path, Linux hosts only
.github/workflows/  CI: a full install on a clean Ubuntu 24.04 runner
```

## License

Apache-2.0. See [LICENSE](LICENSE).

The Husarion packages this builds on are published separately by Husarion under
their own licenses, and are cloned at install time rather than vendored here.
