"""Strip cache and frame regressions in an emulated Kitty terminal.

Usage: python3 -I tests/test_performance.py zig-out/bin/fancy-cat
"""
import json
import os
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import ROWS, Viewer  # noqa: E402

PDF = Path(__file__).resolve().parent / "fixtures/test.pdf"
BIN = str(Path(sys.argv[1]).resolve())
WHEEL_DOWN = b"\x1b[<65;40;15M"


class FrameViewer(Viewer):
    def __init__(self, *args):
        self.frames = []
        super().__init__(*args)

    def csi(self, params, final):
        super().csi(params, final)
        if params == "?2026" and final == "l":
            self.frames.append(placed_ids(self))


def start(root, megabytes):
    config = root / "config/fancy-cat/config.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({
        "StatusBar": {"enabled": True, "items": ["P<page>/<total_pages>"]},
        "FileMonitor": {"enabled": False},
        "General": {"remember_page": False, "incremental_search": True,
                    "smooth_scroll": False, "wheel_step": 12},
        "Cache": {"enabled": True, "memory_mb": megabytes},
    }))
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(config.parent.parent),
               XDG_STATE_HOME=str(root / "state"), TERM="xterm-256color")
    viewer = FrameViewer(BIN, [str(PDF), "2"], env)
    viewer.pump(1.5)
    return viewer


def placed_ids(viewer):
    return {image_id for image_id, _ in viewer.placements}


def cache_bytes(viewer):
    return sum(len(rgb) for _, _, rgb in viewer.images.values())


with tempfile.TemporaryDirectory(prefix="fancy-cat-perf-") as directory:
    root = Path(directory)
    viewer = start(root / "warm", 64)
    try:
        original = viewer.compose(None)
        start_raw = len(viewer.raw)
        viewer.send(b"\x1b[<35;16;7M" * 40, 0.2)
        assert len(viewer.raw) == start_raw, "hover issued terminal output on a settled view"

        before_placements = viewer.placements.copy()
        start_raw = len(viewer.raw)
        viewer.send(WHEEL_DOWN * 10, 0.2)
        delta = viewer.raw[start_raw:]
        common = before_placements.keys() & viewer.placements.keys()
        assert common, "wheel scroll did not reuse visible strips"
        for key in common:
            image, placement = key
            put = f"\x1b_Ga=p,i={image},p={placement},".encode()
            if before_placements[key] == viewer.placements[key]:
                assert put not in delta, "unchanged strip was placed again"
            else:
                delete = f"\x1b_Ga=d,d=i,i={image},p={placement},q=2".encode()
                assert delta.index(delete) < delta.index(put), "strip was moved without deleting its old placement"
        wheeled = viewer.compose(None)
        assert wheeled != original, "wheel burst did not scroll"
        viewer.send("H:y+120\r", 0.2)
        assert viewer.compose(None) == wheeled, "wheel reports changed the total distance"

        viewer.send("H", 0.2)
        base_ids = set(viewer.images)
        viewer.send("/quantum", 0.35)
        assert base_ids <= viewer.images.keys(), "search discarded cached base strips"
        assert any(i not in base_ids for i in placed_ids(viewer)), "search did not place a highlight"
        viewer.send("\r", 0.2)
        viewer.send("n", 0.2)
        viewer.send("N", 0.2)
        assert viewer.line(ROWS - 1).strip() == "P2/5", "N did not return to the previous hit"
        assert base_ids <= viewer.images.keys(), "n/N discarded cached base strips"
        viewer.send("\x1b", 0.25)
        assert all(len(viewer.images[i][2]) == viewer.images[i][0] * viewer.images[i][1] * 3
                   for i in placed_ids(viewer)), "cleared highlights are still placed"

        # Changing both the view and zoom before earlier jobs finish must
        # settle to the same pixels as issuing only the final commands.
        viewer.send("4G+a2G", 0.35)
        resized = viewer.compose(None)
        viewer.send("s2Ga", 0.35)
        assert viewer.line(ROWS - 1).strip() == "P2/5"
        assert viewer.compose(None) == resized, "an old job survived the zoom or page jump"

        cached_page = placed_ids(viewer)
        viewer.send("J", 0.4)
        assert cached_page <= viewer.images.keys(), "page turn discarded usable cached strips"
        viewer.send("K", 0.4)
        assert placed_ids(viewer) == cached_page, "backward turn missed a fully cached page"
    finally:
        viewer.send("q")
        assert viewer.wait_exit() == 0, "clean quit"
        os.close(viewer.fd)

    viewer = start(root / "bounded", 4)
    try:
        # At this width each full strip is 768,000 bytes and the viewport
        # needs three. The cache cannot hold the first and last page tops.
        start_ids = set(viewer.images)
        assert len(start_ids - placed_ids(viewer)) >= 1, "no initial lookahead"
        viewer.send("4G", 0.5)
        assert viewer.line(ROWS - 1).strip() == "P4/5"
        assert start_ids - set(viewer.images), "distant strips were not evicted"
        assert set(viewer.images) - placed_ids(viewer), "lookahead stopped at capacity"
        assert cache_bytes(viewer) <= 4 * 1024 * 1024, "tile cache exceeded the configured budget"
        viewer.send("J", 0.5)
        viewer.send("K", 0.5)
        assert set(viewer.images) - placed_ids(viewer), "reverse movement lost lookahead"
    finally:
        viewer.send("q")
        assert viewer.wait_exit() == 0, "clean quit"
        os.close(viewer.fd)

    viewer = start(root / "cold-turns", 0)
    try:
        for key, page in (("J", "P3/5"), ("K", "P2/5")):
            before = placed_ids(viewer)
            viewer.frames.clear()
            viewer.send(key, 0.45)
            after = placed_ids(viewer)
            assert before and after and before.isdisjoint(after)
            assert viewer.line(ROWS - 1).strip() == page
            assert viewer.frames and all(frame in (before, after) for frame in viewer.frames), (
                f"{key} exposed an empty or partially rendered viewport"
            )
        assert cache_bytes(viewer) == sum(
            len(viewer.images[i][2]) for i in placed_ids(viewer)
        ), "temporary transition exceeded the settled cache budget"
    finally:
        viewer.send("q")
        assert viewer.wait_exit() == 0, "clean quit"
        os.close(viewer.fd)


print("PASS: idle output, wheel distance, cached search, stale jobs, bounded lookahead, synchronized page turns")
