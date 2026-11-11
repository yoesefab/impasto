#!/usr/bin/env python3
# ╭──────────────────────────────────────────────────────────────────────────╮
# │                                                                          │
# │   P A C K A G E S                                                        │
# │   package queries · apt, read only                                       │
# │                                                                          │
# │   github.com/andreumassanet/impasto                                      │
# │                                                                          │
# ╰──────────────────────────────────────────────────────────────────────────╯

"""Read installed packages and search the Ubuntu repositories.

    installed        every installed package, with its summary, whether it
                     was marked manual, and whether it is outside the
                     Ubuntu archive
    search TERM      packages whose name contains TERM, ranked exact,
                     prefix, then name

Read-only: installing and upgrading run in a terminal, where apt can ask
for a password and confirmation.
"""

import json
import os
import shutil
import subprocess
import sys

# Rows whose version and summary are filled in. The rest of a long search
# is counted, not shown.
LISTED = 160

LISTS = "/var/lib/apt/lists"

ENV = dict(os.environ, LANG="C", LC_ALL="C")

# apt-cache search compiles the term as a POSIX extended regular expression.
_PATTERN_META = set(".^$*+?()[]{}|\\")

_LZ4 = None


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


def human_size(raw):
    """Bytes, written as '1.50 MiB'."""
    try:
        size = float(raw)
    except (TypeError, ValueError):
        return raw or ""
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    index = 0
    while size >= 1024 and index < len(units) - 1:
        size /= 1024
        index += 1
    return f"{size:.2f} {units[index]}"


def parse_apt_installed(text, explicit, foreign_names):
    """Rows from `name\\tversion\\tsummary\\tsize_kb`.

    Installed-Size is kilobytes. `explicit` is None when every package
    counts as manual. `foreign_names` are the ones the panel flags.
    """
    packages = []
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        name = parts[0].strip()
        if not name:
            continue
        version = parts[1].strip() if len(parts) > 1 else ""
        description = parts[2].strip() if len(parts) > 2 else ""
        size = ""
        if len(parts) > 3 and parts[3].strip():
            try:
                size = human_size(float(parts[3].strip()) * 1024)
            except (TypeError, ValueError):
                size = ""
        packages.append({
            "name": name,
            "version": version,
            "description": description,
            "size": size,
            "explicit": True if explicit is None else name in explicit,
            "aur": name in foreign_names,
        })
    return packages


def parse_apt_search(text, term):
    """Rows from `name\\tversion\\tdescription`, kept when the name contains the term."""
    rows = []
    for line in text.splitlines():
        raw = line.strip()
        if not raw:
            continue
        name, version, description = (raw.split("\t", 2) + ["", ""])[:3]
        name = name.strip()
        if not name or term not in name.lower():
            continue
        rows.append({
            "name": name,
            "version": version.strip(),
            "source": "ubuntu",
            "installed": False,
            "description": description.strip(),
        })
    return rows


def run(command, timeout=60):
    try:
        return subprocess.run(command, capture_output=True, text=True,
                              timeout=timeout, env=ENV)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"{command[0]} failed: {error}", file=sys.stderr)
        return None


def literal_pattern(term):
    return "".join("\\" + char if char in _PATTERN_META else char for char in term)


def rank(name, term):
    """0 exact, 1 prefix, 2 anywhere in the name."""
    folded = name.lower()
    if folded == term:
        return 0
    return 1 if folded.startswith(term) else 2


def lz4_library():
    """liblz4, which apt uses to store the lists, or None."""
    global _LZ4
    if _LZ4 is False:
        return None
    if _LZ4 is not None:
        return _LZ4
    try:
        import ctypes
        lib = ctypes.CDLL("liblz4.so.1")
        lib.LZ4F_createDecompressionContext.argtypes = [
            ctypes.POINTER(ctypes.c_void_p), ctypes.c_uint]
        lib.LZ4F_createDecompressionContext.restype = ctypes.c_size_t
        lib.LZ4F_freeDecompressionContext.argtypes = [ctypes.c_void_p]
        lib.LZ4F_freeDecompressionContext.restype = ctypes.c_size_t
        lib.LZ4F_decompress.argtypes = [
            ctypes.c_void_p,
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t),
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t),
            ctypes.c_void_p,
        ]
        lib.LZ4F_decompress.restype = ctypes.c_size_t
        lib.LZ4F_isError.argtypes = [ctypes.c_size_t]
        lib.LZ4F_isError.restype = ctypes.c_uint
    except (OSError, AttributeError):
        _LZ4 = False
        return None
    _LZ4 = (lib, ctypes)
    return _LZ4


def decompress_lz4(path):
    """The bytes of an lz4 frame, or None when it cannot be read."""
    loaded = lz4_library()
    if loaded is None:
        return None
    lib, ctypes = loaded
    try:
        data = open(path, "rb").read()
    except OSError:
        return None
    ctx = ctypes.c_void_p()
    code = lib.LZ4F_createDecompressionContext(ctypes.byref(ctx), 100)
    if lib.LZ4F_isError(code):
        return None
    out = bytearray()
    try:
        src = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
        src_off = 0
        dst = ctypes.create_string_buffer(1 << 20)
        while src_off < len(data):
            dst_size = ctypes.c_size_t(len(dst))
            src_size = ctypes.c_size_t(len(data) - src_off)
            hint = lib.LZ4F_decompress(
                ctx, dst, ctypes.byref(dst_size),
                ctypes.cast(ctypes.addressof(src) + src_off, ctypes.c_void_p),
                ctypes.byref(src_size), None)
            if lib.LZ4F_isError(hint):
                return None
            out += dst.raw[:dst_size.value]
            consumed = src_size.value
            if consumed == 0 and dst_size.value == 0:
                break
            src_off += consumed
            if hint == 0:
                break
    finally:
        lib.LZ4F_freeDecompressionContext(ctx)
    return bytes(out)


def names_in_list(path):
    """Package names declared in one lists file."""
    names = set()
    if path.endswith(".lz4"):
        blob = decompress_lz4(path)
        if not blob:
            return names
        lines = (line.decode("utf-8", "replace") for line in blob.splitlines())
    else:
        try:
            handle = open(path, encoding="utf-8", errors="replace")
        except OSError:
            return names
        lines = handle
    try:
        for line in lines:
            if not line.startswith("Package:"):
                continue
            name = line[8:].strip()
            if name:
                names.add(name)
    finally:
        if hasattr(lines, "close"):
            lines.close()
    return names


def archive_names():
    """Names published under ubuntu.com, or None when the lists directory is missing."""
    if not os.path.isdir(LISTS):
        return None
    names = set()
    try:
        entries = list(os.scandir(LISTS))
    except OSError:
        return None
    for entry in entries:
        if "ubuntu.com" not in entry.name:
            continue
        try:
            if not entry.is_file():
                continue
        except OSError:
            continue
        names.update(names_in_list(entry.path))
    return names


def foreign_names(installed_names):
    """Installed names that no ubuntu.com list publishes.

    A missing lists directory means nothing is marked foreign.
    """
    archive = archive_names()
    if archive is None:
        return set()
    return {name for name in installed_names if name not in archive}


def without_summary(text):
    """`name version size` becomes `name version <empty summary> size`."""
    lines = []
    for line in text.splitlines():
        if not line.strip():
            continue
        name, sep, rest = line.partition("\t")
        if not sep:
            continue
        version, sep2, size = rest.partition("\t")
        lines.append(f"{name}\t{version}\t\t{size}" if sep2 else f"{name}\t{version}\t\t")
    return "\n".join(lines)


def explicit_names():
    """Manual packages, or None when apt-mark did not answer."""
    result = run(["apt-mark", "showmanual"])
    if result is None or result.returncode != 0:
        return None
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def installed_name_set():
    result = run(["dpkg-query", "-W", "-f", r"${Package}\n"])
    if result is None or result.returncode != 0:
        return set()
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


# ── INSTALLED ───────────────────────────────────────────────────────────────


def installed():
    summary = r"${Package}\t${Version}\t${binary:Summary}\t${Installed-Size}\n"
    result = run(["dpkg-query", "-W", "-f", summary])
    text = None
    if result is not None and result.returncode == 0:
        text = result.stdout
    else:
        plain = r"${Package}\t${Version}\t${Installed-Size}\n"
        result = run(["dpkg-query", "-W", "-f", plain])
        if result is not None and result.returncode == 0:
            text = without_summary(result.stdout)
    if text is None:
        print(json.dumps({"available": False, "manager": "apt"}))
        return

    names = [line.split("\t", 1)[0].strip()
             for line in text.splitlines() if line.split("\t", 1)[0].strip()]
    print(json.dumps({
        "available": True,
        "manager": "apt",
        "helper": "",
        "packages": parse_apt_installed(text, explicit_names(), foreign_names(names)),
    }))


# ── SEARCH ──────────────────────────────────────────────────────────────────


def search_names(text, term):
    names = []
    seen = set()
    for line in text.splitlines():
        raw = line.strip()
        if not raw:
            continue
        name = raw.split(" - ", 1)[0].strip()
        folded = name.lower()
        if not name or term not in folded or folded in seen:
            continue
        seen.add(folded)
        names.append(name)
    return names


def parse_show(text):
    """Version and the first description line, keyed by package name."""
    details = {}
    current = None
    for line in text.splitlines():
        if not line.strip():
            current = None
            continue
        if line[:1].isspace():
            continue
        key, sep, value = line.partition(":")
        if not sep:
            continue
        key = key.strip()
        value = value.strip()
        if key == "Package":
            current = value
            details.setdefault(current, {})
            continue
        if current is None:
            continue
        slot = details[current]
        if key == "Version" and "version" not in slot:
            slot["version"] = value
        elif key == "Description-en":
            slot["description"] = value
        elif key == "Description" and "description" not in slot:
            slot["description"] = value
    return details


def offline(term):
    print(json.dumps({
        "term": term,
        "results": [],
        "total": 0,
        "repos": 0,
        "aurCount": 0,
        "aur": "offline",
        "manager": "apt",
    }))


def search(term):
    term = term.strip().lower()
    if len(term) < 2:
        print(json.dumps({
            "term": term,
            "results": [],
            "total": 0,
            "repos": 0,
            "aurCount": 0,
            "aur": "short",
            "manager": "apt",
        }))
        return

    result = run(["apt-cache", "search", "--names-only", "--", literal_pattern(term)])
    if result is None or result.returncode != 0:
        if result is not None:
            print("apt-cache did not answer", file=sys.stderr)
        offline(term)
        return

    names = search_names(result.stdout, term)
    names.sort(key=lambda name: (rank(name, term), name))
    shown = names[:LISTED]
    details = {}
    if shown:
        shown_result = run(["apt-cache", "show", "--no-all-versions", *shown])
        if shown_result is not None and shown_result.stdout:
            details = parse_show(shown_result.stdout)

    lines = []
    for name in shown:
        info = details.get(name, {})
        description = info.get("description", "").replace("\t", " ")
        lines.append(f"{name}\t{info.get('version', '')}\t{description}")
    rows = parse_apt_search("\n".join(lines), term)
    mine = installed_name_set()
    for row in rows:
        row["installed"] = row["name"] in mine
    rows.sort(key=lambda row: (rank(row["name"], term), row["name"]))

    print(json.dumps({
        "term": term,
        "results": rows,
        "total": len(names),
        "repos": len(names),
        "aurCount": 0,
        "aur": "off",
        "manager": "apt",
    }))


def main():
    verb = sys.argv[1] if len(sys.argv) > 1 else ""
    if verb == "installed":
        installed()
    elif verb == "search" and len(sys.argv) > 2:
        search(" ".join(sys.argv[2:]))
    else:
        print("usage: packages.py installed | search TERM", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
