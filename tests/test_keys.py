"""Zathura key bindings, checked in an emulated Kitty-graphics terminal.

Usage: python3 -I tests/test_keys.py zig-out/bin/fancy-cat
"""
import base64
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import ROWS, XPIX, YPIX, Viewer  # noqa: E402

BIN = os.path.abspath(sys.argv[1])
PDF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "test.pdf")
CTRL = {k: chr(ord(k) - 96) for k in "bdfinotuy"}
SHIFT_SPACE, CTRL_I = "\x1b[32;2u", "\x1b[105;5u"
PAGE_DOWN, PAGE_UP, HOME, END = "\x1b[6~", "\x1b[5~", "\x1b[H", "\x1b[F"
failures = []
CELL_HEIGHT = YPIX // ROWS
ROW_BYTES = XPIX * CELL_HEIGHT * 3


def check(name, ok):
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        failures.append(name)


home = tempfile.mkdtemp(prefix="fancy-cat-test-")
os.makedirs(os.path.join(home, "config/fancy-cat"))
with open(os.path.join(home, "config/fancy-cat/config.json"), "w") as f:
    json.dump({"StatusBar": {"enabled": True, "items": ["P<page>/<total_pages>"]},
               "FileMonitor": {"enabled": False},
               "General": {"remember_page": False, "smooth_scroll": True,
                           "scroll_step": 40, "wheel_step": 24}}, f)
env = {"HOME": home, "XDG_CONFIG_HOME": home + "/config", "XDG_STATE_HOME": home + "/state",
       "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LANG": "C.UTF-8"}

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


def copied():
    found = re.findall(rb"\x1b\]52;c;([A-Za-z0-9+/=]*)", bytes(v.raw))
    return base64.b64decode(found[-1]).decode() if found else None


top = v.compose(None)
half2 = press(CTRL["d"], CTRL["d"])
full = press("gg", CTRL["f"])
check("Ctrl+d twice scrolls as far as Ctrl+f", half2 == full)
check("2 Ctrl+d scrolls as far as Ctrl+f", press("gg", "2", CTRL["d"]) == full)
check("Ctrl+u twice returns", press(CTRL["u"], CTRL["u"]) == top)
check("Space scrolls a view", press(" ") == full)
check("Shift+Space scrolls back", press(SHIFT_SPACE) == top)
check("Ctrl+b scrolls back", press(" ", CTRL["b"]) == top)

press(PAGE_DOWN)
check("Page Down: next page", page() == "P2/5")
press(PAGE_UP)
check("Page Up: previous page", page() == "P1/5")
end = press("G")
check("End matches G", press("gg", END) == end)
check("Home matches gg", press(HOME) == top)

two = press("2G")
bottom = press("L")
check("L shows the page bottom", bottom != two and page() == "P2/5")
check("H returns to the page top", press("H") == two)
check("P snaps to the page", press("L", "P") == two)

three = press("3G")
press("gg")
check("Ctrl+o returns from gg", press(CTRL["o"]) == three)
check("Ctrl+o again returns to before 3G", press(CTRL["o"]) == two)
check("Ctrl+i goes forward", press(CTRL_I) == three)

press("3G", "m", "a", "gg")
check("'a returns to mark a", press("'", "a") == three)
press("'", "b")
check("an unset mark says so", v.line(ROWS - 1).strip() == "Mark not set")

fit_page = press("a")
check("a fits the whole page", fit_page != three)
check("s fits the width again", press("s") == three)

single = press("gg", "d")
paired = press("D")
check("D moves page 1 to the left column", paired != single)
press("D", "d")

press("R")
check("R reloads in place", v.compose(None) == top and page() == "P1/5")

press("Y")
check("Y copies the file path", copied() == PDF)
press("2G", "c", "2")
check("c copies a link", copied() == "https://example.com/fancy")
press("F", "1")
check("F shows an internal link's page", v.line(ROWS - 1).strip() == "Page 3")
press("F", "2")
check("F shows an external link", v.line(ROWS - 1).strip() == "https://example.com/fancy")

def scroll_positions(label, event):
    start = len(v.raw)
    visible = v.placements.copy()
    press(event)
    common = visible.keys() & v.placements.keys()
    check(f"{label} keeps rendered strips", bool(common))
    if not common:
        return []
    image, _ = min(common, key=lambda key: visible[key][0])
    pattern = (rb"\x1b\[(\d+);\d+H\x1b_Ga=p,i=%d,p=1,x=\d+,y=(\d+),"
               rb"w=\d+,h=\d+,X=\d+,Y=(\d+),") % image
    tops = [(int(row) - 1) * CELL_HEIGHT - int(source_y) + int(offset_y)
            for row, source_y, offset_y in re.findall(pattern, v.raw[start:])]
    row, _, _, offset_y, _, source_y, _, _ = visible[(image, 1)]
    original_top = row * CELL_HEIGHT + offset_y - source_y
    return [original_top - top for top in tops]


press("2G", ":180%\r", "H")
check("j covers 60%, 90%, then 100% of the requested distance",
      scroll_positions("j", "j") == [24, 36, 40])
wheel_down = b"\x1b[<65;40;15M"
check("the wheel spreads one scroll event across three frames",
      scroll_positions("single wheel event", wheel_down) == [14, 22, 24])
burst = scroll_positions("wheel burst", wheel_down * 3)
check("the complete wheel burst travels 72 px", len(burst) >= 3 and burst[-1] == 72)

scrolled = v.compose(None)
press(CTRL["n"])
check("hiding the status bar preserves manual zoom and scroll position",
      v.compose(None)[:-ROW_BYTES] == scrolled[:-ROW_BYTES])
check("the hidden status bar gives the bottom row back to the PDF",
      max(row * CELL_HEIGHT + offset_y + height for row, _, _, offset_y, _, _, _, height
          in v.placements.values()) == YPIX)
check("Ctrl+n restores the status bar on the last row",
      press(CTRL["n"]) == scrolled and v.line(ROWS - 1).strip() == "P2/5")

v.send("q")
check("quits cleanly", v.wait_exit() == 0)
check("no panic", not any(n in bytes(v.raw) for n in (b"panic", b"Segmentation")))
sys.exit(1 if failures else 0)
