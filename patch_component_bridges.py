#!/usr/bin/env python3
"""Add the current component names to Husarion's gz_components bridge table.

pins.env explains the whole of it above COMPONENT_BRIDGE_ALIASES. Briefly: the
`type:` string in rosbot_description's component configs is read in two places
that do not share a table. components.urdf.xacro builds the sensor into Gazebo
and knows the current names. gz_components.launch.py starts the ros_gz_bridge
that carries the sensor into ROS 2 and still looks the string up in a dict of
the old SKU codes. Upstream renamed the strings and taught only the first of
the two, so the lidar spins in Gazebo and /scan has no ROS publisher.

install.sh runs this after vcs import and before the build. It edits one file
in the workspace, in place, and it is safe to run again.

Usage:
    patch_component_bridges.py <path to gz_components.launch.py> "<type>:<launch> ..."

Exit codes, which install.sh turns into a line of output:
    0  entries inserted
    2  an earlier run already inserted them
    3  the table already knows every name, so there is nothing to do
    4  the file is not shaped the way this expects, and nothing was written
"""

import os
import sys
import tempfile

MARKER = "ros2-env: canonical component names, see COMPONENT_BRIDGE_ALIASES in pins.env"
ANCHOR = "components_types_with_names = {"


def parse_pairs(raw):
    """Split "<type>:<launch> ..." into pairs, or return None on a bad item."""
    pairs = []
    for item in raw.split():
        name, sep, launch = item.partition(":")
        if not sep or not name or not launch:
            sys.stderr.write("malformed alias %r, expected <type>:<launch>\n" % item)
            return None
        pairs.append((name, launch))
    return pairs


def write_atomically(path, text):
    """Replace path's contents without ever leaving it half written.

    A truncated launch file breaks the workspace and there is no copy of the
    original to put back, so the new text lands in a sibling file first and the
    rename swaps it in with one syscall.
    """
    directory = os.path.dirname(os.path.abspath(path))
    mode = os.stat(path).st_mode
    handle, temporary = tempfile.mkstemp(dir=directory, prefix=".gz_components.")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(__doc__)
        return 4

    path = argv[1]
    pairs = parse_pairs(argv[2])
    if pairs is None:
        return 4
    if not pairs:
        return 3

    try:
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
    except OSError as error:
        sys.stderr.write("%s\n" % error)
        return 4

    if MARKER in source:
        return 2

    # Every name matched as a key, with its colon. Several of them are also
    # values in that dict ("ANT02": "teltonika"), and a bare name finds those.
    #
    # Asked before the file's shape is checked, so that an upstream fix which
    # also restructures the lookup reports "nothing to do" rather than a file
    # this does not recognise. What is left after this point is a table that
    # genuinely lacks the names.
    if all('"%s":' % name in source for name, _ in pairs):
        return 3

    start = source.find(ANCHOR)
    if start < 0:
        sys.stderr.write("%r not found in %s\n" % (ANCHOR, path))
        return 4

    # The dict is a flat literal of string pairs, so the first closing brace
    # after it is its own. Anything else means upstream restructured the lookup,
    # and this should stay out of it rather than guess.
    end = source.find("}", start)
    if end < 0:
        sys.stderr.write("unterminated %r in %s\n" % (ANCHOR, path))
        return 4
    table = source[start:end]

    line_start = source.rfind("\n", 0, start) + 1
    outer = source[line_start:start]
    if outer.strip():
        sys.stderr.write("%r is not at the start of its line in %s\n" % (ANCHOR, path))
        return 4
    indent = outer + "    "

    insert_at = source.index("\n", start) + 1
    added = ["%s# %s\n" % (indent, MARKER)]
    added += [
        '%s"%s": "%s",\n' % (indent, name, launch)
        for name, launch in pairs
        if '"%s":' % name not in table
    ]

    write_atomically(path, source[:insert_at] + "".join(added) + source[insert_at:])
    sys.stderr.write("%d entries added to %s\n" % (len(added) - 1, path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
