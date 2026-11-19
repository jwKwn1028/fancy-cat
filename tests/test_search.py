"""Incremental search, checked in an emulated Kitty-graphics terminal.

Usage: python3 -I tests/test_search.py zig-out/bin/fancy-cat
"""
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import ROWS, Viewer  # noqa: E402

BIN = os.path.abspath(sys.argv[1])
PDF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "test.pdf")
failures = []


def check(name, ok):
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        failures.append(name)


home = tempfile.mkdtemp(prefix="fancy-cat-test-")
os.makedirs(os.path.join(home, "config/fancy-cat"))
with open(os.path.join(home, "config/fancy-cat/config.json"), "w") as f:
    json.dump({"StatusBar": {"enabled": True, "items": ["P<page>/<total_pages>"],
                            "style": {"fg": "#ffffff", "bg": "#292d3e"}},
               "FileMonitor": {"enabled": False},
               "General": {"remember_page": False, "incremental_search": True}}, f)
env = {"HOME": home, "XDG_CONFIG_HOME": home + "/config", "XDG_STATE_HOME": home + "/state",
       "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "C.UTF-8"}

v = Viewer(BIN, [PDF], env)
v.pump(2.5)


def press(*keys):
    for k in keys:
        v.send(k, 0.35)
    return v.compose(None)


def page():
    for row in (ROWS - 1, ROWS - 2):
        text = v.line(row).strip()
        if re.fullmatch(r"P\d+/\d+", text):
            return text
    return ""


top = v.compose(None)
press("/")
before = len(v.raw)
press("q")
typed = re.search(rb"\x1b\[%d;2H((?:\x1b\[[0-9;:]*m)*)q" % ROWS, v.raw[before:])
style = typed.group(1) if typed else b""
check("typed text uses white on the configured dark bar color",
      bool(re.search(rb"\x1b\[38[:;]2[:;]255[:;]255[:;]255m", style) and
           re.search(rb"\x1b\[48[:;]2[:;]41[:;]45[:;]62m", style)))
check("the first letter finds a page", page() == "P2/5")
press(*"uantum o")
check("more letters move on to the next match", page() == "P4/5")
press("\x7f")
check("deleting a letter goes back", page() == "P2/5")
check("Escape returns to where the search began", press("\x1b") == top and page() == "P1/5")

press("/", *"zzz")
check("no match stays put", page() == "P1/5")
press("\x1b")

press("5G", "?", *"quantum")
check("? searches backward", page() == "P4/5")
press("\r")
check("Enter keeps the match", page() == "P4/5")
press("n")
check("n continues backward", page() == "P3/5")
press("\x0f")
check("Ctrl+o returns before n", page() == "P4/5")
press("\x0f")
check("Ctrl+o again returns to where the search began", page() == "P5/5")

press("gg")
v.send("/quantum noise", 0.05)
v.pump(1.5)
check("typing faster than the search still lands on the match", page() == "P3/5")
press("\r")

v.send("q")
check("quits cleanly", v.wait_exit() == 0)
check("no panic", not any(n in bytes(v.raw) for n in (b"panic", b"Segmentation")))
sys.exit(1 if failures else 0)
