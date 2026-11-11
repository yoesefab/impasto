#!/usr/bin/env python3
# ╭──────────────────────────────────────────────────────────────────────────╮
# │                                                                          │
# │   U P D A T E S                                                          │
# │   pending updates · read only                                            │
# │                                                                          │
# │   github.com/andreumassanet/impasto                                      │
# │                                                                          │
# ╰──────────────────────────────────────────────────────────────────────────╯

"""List pending updates, read-only.

`apt list --upgradable` reports what an upgrade would install. apt exits 0
whether or not anything is pending. Upgrades run in a terminal, never from
here. When apt does not answer the result is unavailable and the module is
hidden.
"""

import json
import os
import shutil
import subprocess
import sys

# How many names ride along for the module's one line; the panel reads the
# whole list from `updates`.
LISTED = 15

ENV = dict(os.environ, LANG="C", LC_ALL="C")


def run(command, timeout=120):
    try:
        return subprocess.run(command, capture_output=True, text=True,
                              timeout=timeout, env=ENV)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"{command[0]} failed: {error}", file=sys.stderr)
        return None


def family():
    """ubuntu when os-release says ID=ubuntu, otherwise ""."""
    path = os.environ.get("IMPASTO_OS_RELEASE", "/etc/os-release")
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return ""
    for line in text.splitlines():
        key, _, value = line.partition("=")
        if key.strip() != "ID":
            continue
        ident = value.strip().strip('"').strip("'")
        return "ubuntu" if ident == "ubuntu" else ""
    return ""


def manager():
    """apt on Ubuntu, or wherever apt-get and dpkg-query are both installed."""
    if family() == "ubuntu" or (shutil.which("apt-get") and shutil.which("dpkg-query")):
        return "apt"
    return ""


def parse_apt(text):
    """Rows from `apt list --upgradable`.

    `kitty/noble-updates 0.36.0 amd64 [upgradable from: 0.32.2]` gives the
    name before the slash, the version offered, and the version in brackets.
    """
    rows = []
    for line in text.splitlines():
        raw = line.strip()
        if not raw or raw.startswith("Listing") or raw.startswith("WARNING"):
            continue
        parts = raw.split()
        if len(parts) < 2:
            continue
        name = parts[0].split("/", 1)[0]
        if not name:
            continue
        previous = ""
        marker = "[upgradable from:"
        if marker in raw:
            previous = raw.split(marker, 1)[1].split("]", 1)[0].strip()
        rows.append({
            "name": name,
            "from": previous,
            "to": parts[1],
            "source": "repo",
        })
    return rows


def main():
    result = run(["apt", "list", "--upgradable"])
    if result is None or result.returncode != 0:
        print("apt list --upgradable did not answer", file=sys.stderr)
        print(json.dumps({"available": False, "manager": "apt"}))
        return
    rows = parse_apt(result.stdout)
    print(json.dumps({
        "available": True,
        "manager": "apt",
        "tool": "apt",
        "aur": False,
        "count": len(rows),
        "packages": [row["name"] for row in rows[:LISTED]],
        "updates": rows,
    }))


if __name__ == "__main__":
    main()
