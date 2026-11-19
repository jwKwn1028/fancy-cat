"""PDF mouse interactions in an emulated Kitty-graphics terminal.

Usage: python3 -B -I tests/test_mouse.py zig-out/bin/fancy-cat
"""
import base64
import json
import os
from pathlib import Path
import re
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from harness import ROWS, XPIX, Viewer  # noqa: E402

PDF = Path(__file__).resolve().parent / "fixtures/test.pdf"
# Page 2 of test.typ is 15 × 20 cm and starts aligned to the top of the view.
PAGE_W, PAGE_H = (length / 2.54 * 72 for length in (15, 20))
ZOOM = XPIX / PAGE_W


def mouse(button, point, release=False, *, zoom=ZOOM):
    x, y = point
    return f"\x1b[<{button};{round(x * zoom) + 1};{round(y * zoom) + 1}{'m' if release else 'M'}"


def click(point, mods=0, *, zoom=ZOOM):
    return mouse(mods, point, zoom=zoom) + mouse(mods, point, True, zoom=zoom)


def copied(viewer):
    return [base64.b64decode(text).decode()
            for text in re.findall(rb"\x1b\]52;c;([A-Za-z0-9+/=]+)", viewer.raw)]


def highlight_ids(viewer):
    return {i for i, (width, height, rgba) in viewer.images.items() if len(rgba) == 4 * width * height}


with tempfile.TemporaryDirectory(prefix="fancy-cat-mouse-") as directory:
    root = Path(directory)
    config = root / "config/fancy-cat/config.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({
        "StatusBar": {"enabled": True, "items": ["P<page>/<total_pages>"]},
        "FileMonitor": {"enabled": False},
        "General": {"remember_page": False, "trim_margins": False, "smooth_scroll": True},
    }))
    log = root / "opened"
    opener = root / "xdg-open"
    opener.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$FANCY_LINK_LOG"\n')
    opener.chmod(0o755)
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(config.parent.parent),
               XDG_STATE_HOME=str(root / "state"), TERM="xterm-256color",
               PATH=f"{root}:/usr/bin:/bin", FANCY_LINK_LOG=str(log))
    v = Viewer(str(Path(sys.argv[1]).resolve()), [str(PDF), "2"], env, pixel_mouse=True)
    v.pump(2.0)
    assert b"1002;1003;1004;1016h" in v.raw, "pixel mouse mode"

    internal, external = (120, 110), (125, 136)
    v.send(click(internal, 16), 0.25)
    assert v.line(ROWS - 1).strip() == "P2/5", "Ctrl+click reserved"
    v.send(mouse(0, internal), 0.25)
    assert v.line(ROWS - 1).strip() == "P2/5", "wait for a click's release"
    v.send(mouse(0, internal, True), 0.35)
    assert v.line(ROWS - 1).strip() == "P3/5", "internal link click"
    v.send("\x0f", 0.35)
    assert v.line(ROWS - 1).strip() == "P2/5", "link adds jumplist entry"
    v.send(click(external), 0.35)
    assert log.read_text().splitlines() == ["https://example.com/fancy"], "external link click"

    v.send("f3", 0.35)
    opened = ["https://example.com/fancy", "mailto:reader@example.com"]
    assert log.read_text().splitlines() == opened, "mailto link did not open"
    for key in ("f4", "f5"):
        v.send(key, 0.35)
        assert "Only HTTP, HTTPS and mailto links" in v.line(ROWS - 1), "missing notice for blocked URI"
        assert log.read_text().splitlines() == opened, "blocked URI reached xdg-open"
    v.send("\x1b", 0.25)

    before = v.compose(None)
    v.send(mouse(0, (350, 155)) + mouse(32, (350, 100)) + mouse(0, (350, 100), True), 0.35)
    assert v.compose(None) != before and not copied(v), "dragging blank area pans"
    v.send("H", 0.35)
    assert v.compose(None) == before, "blank drag moved the view on the same page"

    # Drag from inside the first q to just before the space after quantum.
    start, end = (83, 86), (134, 86)
    base_ids = set(v.images)
    v.send(mouse(0, start) + mouse(32, end), 0.3)
    highlights = highlight_ids(v)
    assert highlights and any(i in highlights for i, _ in v.placements), "selection shows while dragging"
    assert base_ids <= v.images.keys(), "selection keeps cached PDF strips"
    assert not copied(v), "clipboard unchanged while dragging"
    v.send(mouse(0, end, True), 0.3)
    assert copied(v) == ["quantum"], copied(v)
    assert highlight_ids(v) == highlights, "selection stays highlighted after release"
    v.send("\x1b", 0.4)
    assert not highlight_ids(v), "Escape clears the highlight"

    word = (130, 86)  # Right half of the last glyph in quantum.
    v.send(click(word) + click(word), 0.35)
    assert copied(v) == ["quantum", "quantum"], copied(v)
    assert highlight_ids(v), "double click highlights the whole word"

    v.send("d", 0.35)
    spread_zoom = XPIX / (2 * PAGE_W + 6)
    right_page_word = (PAGE_W + 6 + 150, 86)
    v.send(click(right_page_word, zoom=spread_zoom) * 2, 0.35)
    assert copied(v) == ["quantum"] * 3, "text selection in the right column"

    v.send("dr2G", 0.35)
    rotated_point = (PAGE_H - internal[1], internal[0])
    v.send(click(rotated_point, zoom=XPIX / PAGE_H), 0.35)
    assert v.line(ROWS - 1).strip() == "P3/5", "link hit testing on a rotated page"

    v.send("q", 0.2)
    assert v.wait_exit() == 0, "clean quit"
    assert b"panic" not in v.raw
    os.close(v.fd)

print("PASS: link handling and scheme restrictions, panning, text selection, and word selection")
