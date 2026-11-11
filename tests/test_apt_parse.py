#!/usr/bin/env python3
"""Parsers and the awww wrapper, without installing anything."""

import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "home" / ".config" / "quickshell" / "scripts"


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AptParse(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packages = load("packages")
        cls.updates = load("updates")

    def test_installed_rows(self):
        text = "kitty\t0.32.2-1ubuntu0.4\tTerminal\t1024\n"
        rows = self.packages.parse_apt_installed(text, {"kitty"}, set())
        self.assertEqual(rows[0]["name"], "kitty")
        self.assertEqual(rows[0]["version"], "0.32.2-1ubuntu0.4")
        self.assertTrue(rows[0]["explicit"])
        self.assertFalse(rows[0]["aur"])
        self.assertEqual(rows[0]["size"], "1.00 MiB")

    def test_foreign_ppa_is_marked(self):
        rows = self.packages.parse_apt_installed(
            "hyprland\t0.56.2-1ppa2\tcompositor\t1\n", None, {"hyprland"})
        self.assertTrue(rows[0]["aur"])

    def test_search_filters_by_name(self):
        text = "kitty\t0.32.2-1ubuntu0.4\tA terminal\nnotkitty-doc\t1\tnotes\n"
        rows = self.packages.parse_apt_search(text, "kitty")
        self.assertEqual([row["name"] for row in rows], ["kitty", "notkitty-doc"])

    def test_upgradable_line(self):
        text = (
            "Listing...\n"
            "kitty/noble-updates 0.36.0 amd64 [upgradable from: 0.32.2-1ubuntu0.4]\n"
        )
        rows = self.updates.parse_apt(text)
        self.assertEqual(rows, [{
            "name": "kitty",
            "from": "0.32.2-1ubuntu0.4",
            "to": "0.36.0",
            "source": "repo",
        }])

    def test_listing_header_is_ignored(self):
        self.assertEqual(self.updates.parse_apt("Listing...\nWARNING: apt\n"), [])


class WallpaperWrapper(unittest.TestCase):
    def test_awww_forwards_to_swww(self):
        text = (ROOT / "lib" / "awww").read_text(encoding="utf-8")
        self.assertIn("exec swww \"$@\"", text)

    def test_awww_daemon_forwards_to_swww_daemon(self):
        text = (ROOT / "lib" / "awww-daemon").read_text(encoding="utf-8")
        self.assertIn("exec swww-daemon \"$@\"", text)


class EmojiFont(unittest.TestCase):
    def test_ubuntu_color_font_is_first(self):
        text = (SCRIPTS / "camera.py").read_text(encoding="utf-8")
        ubuntu = "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf"
        self.assertIn(ubuntu, text)
        self.assertLess(text.index(ubuntu), text.index("/usr/share/fonts/noto/NotoColorEmoji.ttf"))


if __name__ == "__main__":
    unittest.main()
