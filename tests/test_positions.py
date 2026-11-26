"""Remember the page once it settles, on SIGTERM and on a closed terminal, and reopen there.

Usage: python3 -I tests/test_positions.py zig-out/bin/fancy-cat
"""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import Viewer  # noqa: E402

BINARY = str(Path(sys.argv[1]).resolve())
FIXTURE = Path(__file__).resolve().parent / "fixtures/test.pdf"

with tempfile.TemporaryDirectory(prefix="fancy-cat-positions-") as directory:
    root = Path(os.path.realpath(directory))
    config = root / "config/fancy-cat/config.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({
        "StatusBar": {"enabled": True, "items": ["P<page>/<total_pages>"]},
        "General": {"remember_page": True, "smooth_scroll": False, "detect_dpi": False},
        "FileMonitor": {"enabled": False},
        "Cache": {"enabled": False},
    }))
    pdf = root / "doc.pdf"
    shutil.copyfile(FIXTURE, pdf)
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(root / "config"),
               XDG_STATE_HOME=str(root / "state"), TMPDIR=str(root), TERM="xterm-256color")
    positions = root / "state/fancy-cat/positions"

    def saved():
        lines = positions.read_text().splitlines() if positions.exists() else []
        pages = [int(line.split("\t", 1)[0]) for line in lines if line.endswith("\t" + str(pdf))]
        assert len(pages) <= 1, lines
        return pages[0] if pages else None

    def start():
        viewer = Viewer(BINARY, [str(pdf)], env)
        viewer.pump(1.5)
        return viewer

    def page(viewer):
        found = re.search(r"P(\d+)/5", viewer.text())
        assert found, viewer.text()
        return int(found[1])

    def go(viewer, target):
        while page(viewer) < target:
            viewer.send("J", 0.2)
        while page(viewer) > target:
            viewer.send("K", 0.2)

    def exited(viewer, answer=True):
        """Wait for exit, answering the terminal queries vaxis sends on its way out."""
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            pid, _ = os.waitpid(viewer.pid, os.WNOHANG)
            if pid:
                return True
            if answer:
                viewer.pump(0.05)
            else:
                time.sleep(0.05)
        os.kill(viewer.pid, signal.SIGKILL)
        return False

    def eventually(check, seconds=2):
        deadline = time.monotonic() + seconds
        while not check() and time.monotonic() < deadline:
            time.sleep(0.05)
        return check()

    # A settled page is saved while the viewer runs, so even a hard kill keeps it.
    viewer = start()
    assert page(viewer) == 1 and saved() is None
    go(viewer, 3)
    viewer.pump(1.5)
    assert saved() == 3, saved()
    os.kill(viewer.pid, signal.SIGKILL)
    assert exited(viewer, answer=False)
    os.close(viewer.fd)

    # SIGTERM (shutdown) saves the page shown, before it settles.
    viewer = start()
    assert page(viewer) == 3, page(viewer)
    go(viewer, 5)
    os.kill(viewer.pid, signal.SIGTERM)
    # Saved before the viewer waits on its terminal, which may already be dying.
    assert eventually(lambda: saved() == 5), saved()
    assert exited(viewer), "SIGTERM did not end the viewer"
    os.close(viewer.fd)

    # So does a closed terminal (SIGHUP), as when tmux closes the pane.
    viewer = start()
    assert page(viewer) == 5, page(viewer)
    go(viewer, 2)
    os.close(viewer.fd)
    assert exited(viewer, answer=False), "a closed terminal did not end the viewer"
    assert saved() == 2, saved()

    # Viewers stopped together, as at shutdown, all keep their pages.
    copies = [root / f"copy{n}.pdf" for n in range(1, 5)]
    viewers = []
    for copy in copies:
        shutil.copyfile(FIXTURE, copy)
        viewers.append(Viewer(BINARY, [str(copy)], env))
        viewers[-1].pump(1.5)  # Answer its terminal queries before starting the next.
    for number, viewer in enumerate(viewers, 1):
        go(viewer, number + 1)
    for viewer in viewers:
        os.kill(viewer.pid, signal.SIGTERM)
    for viewer in viewers:
        assert exited(viewer)
        os.close(viewer.fd)
    lines = positions.read_text().splitlines()
    for number, copy in enumerate(copies, 1):
        assert f"{number + 1}\t{copy}" in lines, (copy, lines)

    # An unmoved viewer writes nothing.
    viewer = start()
    assert page(viewer) == 2, page(viewer)
    stamp = positions.stat().st_mtime_ns
    viewer.send("q", 0.3)
    assert exited(viewer)
    os.close(viewer.fd)
    assert positions.stat().st_mtime_ns == stamp, "an unmoved viewer rewrote its position"
    assert not list(positions.parent.glob("*.tmp")), "a temporary positions file was left behind"

print("PASS: settled pages, SIGTERM and closed terminals save the page; reopening starts there")
