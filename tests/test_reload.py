"""Live-reload regressions in an emulated Kitty terminal.

Usage: python3 -I tests/test_reload.py zig-out/bin/fancy-cat
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import ROWS, Viewer, XPIX, YPIX  # noqa: E402

BINARY = str(Path(sys.argv[1]).resolve())
CLIPBOARD = b"\x1b]52;c;"
ERROR = "Could not reload PDF"


def pdf_bytes(pages, rgb, width=400):
    # Solid page colors make it clear which document supplied the pixels.
    children = " ".join(f"{3 + 2 * page} 0 R" for page in range(pages))
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        f"<< /Type /Pages /Count {pages} /Kids [{children}] >>".encode(),
    ]
    for page in range(pages):
        stream = f"{rgb} rg 0 0 {width} 600 re f\n".encode()
        objects.extend([
            (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} 600] "
             f"/Resources << >> /Contents {4 + 2 * page} 0 R >>").encode(),
            f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"endstream",
        ])
    output = bytearray(b"%PDF-1.4\n")
    offsets = ["0000000000 65535 f \n"]
    for i, obj in enumerate(objects, 1):
        offsets.append(f"{len(output):010} 00000 n \n")
        output.extend(f"{i} 0 obj\n".encode() + obj + b"\nendobj\n")
    end = len(output)
    output.extend((f"xref\n0 {len(offsets)}\n" + "".join(offsets)
                   + f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\n"
                     f"startxref\n{end}\n%%EOF\n").encode())
    return output


def start(root, watch, *, listen=False, latency=0.03):
    config = root / "config/fancy-cat/config.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({
        "StatusBar": {"enabled": True, "items": ["P<page>/<total_pages> <path>"]},
        "FileMonitor": {"enabled": watch, "latency": latency},
        "General": {"remember_page": False, "timeout": 0.75, "retry_delay": 0.04,
                    "detect_dpi": False},
        "Cache": {"enabled": False},
    }))
    source = root / "live.pdf"
    source.write_bytes(pdf_bytes(6, "0 0 1"))
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(config.parent.parent),
               XDG_STATE_HOME=str(root / "state"), TMPDIR=str(root), TERM="xterm-256color")
    args = ["--listen", str(root / "preview.sock")] if listen else []
    viewer = Viewer(BINARY, [*args, str(source)], env)
    viewer.pump(1.5)
    return viewer, source


def pixels(viewer):
    at = (YPIX // 2 * XPIX + XPIX // 2) * 3
    return viewer.compose(None)[at:at + 3]


def expect_page(viewer, label):
    assert any(viewer.line(i).strip() == f"{label} ~/live.pdf" for i in (ROWS - 1, ROWS - 2)), viewer.text()


def finish(viewer, root):
    viewer.send("q")
    assert viewer.wait_exit() == 0, "clean quit"
    assert not list(root.glob("fancy-cat-*.pdf")), "temporary PDF from a closed viewer"
    os.close(viewer.fd)


with tempfile.TemporaryDirectory(prefix="fancy-cat-test-reload-") as directory:
    root = Path(directory) / "automatic"
    viewer, source = start(root, watch=True)
    try:
        assert pixels(viewer) == b"\0\0\xff"
        assert not list(root.glob("fancy-cat-*.pdf")), "active snapshot still has a directory entry"
        source.write_bytes(b"")
        viewer.pump(0.14)
        initial_ids = set(viewer.placements)
        before = len(viewer.raw)
        viewer.send("4GY", 0.38)
        assert CLIPBOARD in viewer.raw[before:], "file retry blocked input"
        expect_page(viewer, "P4/6")
        assert pixels(viewer) == b"\0\0\xff", "uncached page failed from the saved PDF"
        assert initial_ids.isdisjoint(viewer.placements), "old snapshot did not render the new position"
        snapshot_ids = {i for i, _ in viewer.placements}
        # A valid shorter PDF: the current page must clamp.
        source.write_bytes(pdf_bytes(2, "1 0 0"))
        before = len(viewer.raw)
        viewer.pump(0.6)
        expect_page(viewer, "P2/2")
        assert pixels(viewer) == b"\xff\0\0"
        delta = bytes(viewer.raw[before:])
        old_delete = min(delta.index(f"\x1b_Ga=d,d=I,i={i},q=2".encode()) for i in snapshot_ids)
        for image, _ in viewer.placements:
            upload = delta.index(f",i={image},q=2,m=".encode())
            assert upload < old_delete, "visible contents dropped before a replacement tile arrived"

        # Past the timeout, keep the last PDF usable and detect the file's return.
        source.unlink()
        viewer.pump(1.1)
        assert ERROR in viewer.text(), viewer.text()
        viewer.send("ggY", 0.28)
        expect_page(viewer, "P1/2")
        assert pixels(viewer) == b"\xff\0\0"
        staged = source.with_suffix(".new")
        staged.write_bytes(pdf_bytes(3, "0 1 0"))
        os.replace(staged, source)
        viewer.pump(0.6)
        expect_page(viewer, "P1/3")
        assert pixels(viewer) == b"\0\xff\0"

        # A page-size edit must keep the active fit mode; manual zoom stays fixed.
        source.write_bytes(pdf_bytes(3, "0 1 0", width=800))
        viewer.pump(0.6)
        assert max(width for width, _, _ in viewer.images.values()) == XPIX, "reload used the old fitted scale"
        reloaded = viewer.compose(None)
        viewer.send("s", 0.25)
        assert viewer.compose(None) == reloaded, "reload lost fit-width after a page-size change"
        viewer.send("a", 0.25)
        source.write_bytes(pdf_bytes(3, "0 1 0"))
        viewer.pump(0.6)
        reloaded = viewer.compose(None)
        viewer.send("a", 0.25)
        assert viewer.compose(None) == reloaded, "reload lost fit-page after a page-size change"
        viewer.send(":180%\r", 0.25)
        source.write_bytes(pdf_bytes(3, "0 1 0", width=800))
        viewer.pump(0.6)
        assert max(width for width, _, _ in viewer.images.values()) == 1920, "reload changed manual zoom"
    finally:
        finish(viewer, root)

    root = Path(directory) / "manual"
    viewer, source = start(root, watch=False)
    try:
        source.write_bytes(b"")
        viewer.send("R", 0.14)
        before = len(viewer.raw)
        viewer.send("Y", 0.2)
        assert CLIPBOARD in viewer.raw[before:], "manual retry blocked input"
        viewer.pump(0.55)
        assert ERROR in viewer.text(), viewer.text()
        source.write_bytes(pdf_bytes(2, "1 0 0"))
        viewer.pump(0.2)
        assert pixels(viewer) == b"\0\0\xff", "monitor fired when disabled"
        viewer.send("R", 0.5)
        expect_page(viewer, "P1/2")
        assert pixels(viewer) == b"\xff\0\0"
        # Quit while another retry is waiting.
        source.write_bytes(b"")
        viewer.send("R", 0.14)
    finally:
        finish(viewer, root)

with tempfile.TemporaryDirectory(prefix="fancy-cat-push-reload-") as directory:
    for watch in (True, False):
        root = Path(directory) / str(watch)
        viewer, source = start(root, watch, listen=True, latency=60)
        sock = str(root / "preview.sock")

        def remote(*args):
            subprocess.run([BINARY, "--remote", sock, *args], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        try:
            staged = source.with_suffix(".new")
            staged.write_bytes(pdf_bytes(3, "0 1 0"))
            os.replace(staged, source)
            viewer.pump(0.1)
            expect_page(viewer, "P1/6")
            remote("reload")
            viewer.pump(0.4)
            expect_page(viewer, "P1/3")
            assert pixels(viewer) == b"\0\xff\0", "notification did not reload the published PDF"

            transmits = viewer.transmits
            remote("reload")
            remote("reload")
            viewer.pump(0.3)
            assert viewer.transmits == transmits, "unchanged notifications reloaded the same PDF"

            # Reloads preserve navigation in either order.
            for commands, page in [((b"goto-page\x004", b"reload"), "P4/4"),
                                   ((b"reload", b"goto-page\x002"), "P2/4")]:
                staged.write_bytes(pdf_bytes(4, "1 0 0"))
                os.replace(staged, source)
                os.kill(viewer.pid, signal.SIGSTOP)
                try:
                    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sender:
                        for command in commands:
                            sender.sendto(command, sock)
                finally:
                    os.kill(viewer.pid, signal.SIGCONT)
                viewer.pump(0.5)
                expect_page(viewer, page)
                assert pixels(viewer) == b"\xff\0\0"

            invalid = subprocess.run([BINARY, "--remote", sock, "reload", "extra"],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert invalid.returncode != 0, "reload accepted an extra argument"
        finally:
            finish(viewer, root)

print("PASS: asynchronous manual, polling and notified reload, navigation bursts, last good viewport, timeout and quit")
