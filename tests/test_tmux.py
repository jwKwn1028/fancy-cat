"""Exercise a real local tmux server with an emulated Ghostty client.

Usage: python3 -I tests/test_tmux.py zig-out/bin/fancy-cat
"""
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import COLS, ROWS, XPIX, YPIX, Viewer  # noqa: E402

BINARY = str(Path(sys.argv[1]).resolve())
TMUX = shutil.which("tmux")
FIXTURE = Path(__file__).resolve().parent / "fixtures/test.pdf"
UPLOAD = b"_Ga=T,t=f,U=1"
PLACEHOLDER = "\U0010eeee"


class Terminal(Viewer):
    def apc(self, body):
        if body.startswith("Ga=T,t=f,U=1,"):
            header, _, data = body[1:].partition(";")
            keys = dict(field.split("=", 1) for field in header.split(","))
            path = Path(os.fsdecode(base64.b64decode(data)))
            try:
                pixels = path.read_bytes()
            except FileNotFoundError:
                return  # An image the viewer already retired.
            if keys.get("o") == "z":
                pixels = zlib.decompress(pixels)
            width, height = int(keys["s"]), int(keys["v"])
            assert len(pixels) == width * height * 3
            self.images[int(keys["i"])] = (width, height, pixels)
            return
        super().apc(body)

    def csi(self, params, final):
        if final == "h" and params == "?1004":
            os.write(self.fd, b"\x1b[I")
            return
        if final == "t":
            replies = {
                "14": f"4;{YPIX};{XPIX}",
                "16": f"6;{YPIX // ROWS};{XPIX // COLS}",
                "18": f"8;{ROWS};{COLS}",
            }
            if params in replies:
                os.write(self.fd, f"\x1b[{replies[params]}t".encode())
                return
        if params == ">" and final == "q":
            os.write(self.fd, b"\x1bP>|ghostty 1.3.1\x1b\\")
            return
        super().csi(params, final)


with tempfile.TemporaryDirectory(prefix="fancy-cat-tmux-test-") as directory:
    root = Path(directory)
    PDF = str(root / "live.pdf")
    shutil.copyfile(FIXTURE, PDF)
    preview_socket = str(root / "preview.sock")
    config = root / "config/fancy-cat/config.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({
        "General": {"remember_page": False, "smooth_scroll": False, "scroll_step": 40, "wheel_step": 12},
        "StatusBar": {"enabled": True, "items": ["P<page>/<total_pages>"]},
        "FileMonitor": {"enabled": True, "latency": 0.03},
    }))
    callback = root / "inverse-callback"
    inverse_log = root / "inverse.log"
    callback.write_text('#!/bin/sh\nprintf "%s" "$1" > "$INVERSE_LOG"\n')
    callback.chmod(0o700)
    resolver = root / "inverse-resolver"
    resolver.write_text('#!/bin/sh\nprintf "%s" "$1:3:1"\n')
    resolver.chmod(0o700)
    tmux_cfg = root / "tmux.conf"
    tmux_cfg.write_text(
        "set -g allow-passthrough on\nset -g focus-events on\nset -g status off\n"
        "set -g mouse on\nset -sg escape-time 10\nset -s extended-keys on\nset -s extended-keys-format csi-u\n"
        "bind -n C-MouseDown1Pane if -F -t = '#{mouse_any_flag}' { send-keys -M } { swap-pane -s @ }\n"
        "set -s terminal-features[90] xterm-256color:RGB:extkeys:sync\n"
    )
    socket = root / "tmux.sock"
    env = {"HOME": directory, "TMPDIR": directory, "XDG_CONFIG_HOME": directory + "/config",
           "XDG_STATE_HOME": directory + "/state", "PATH": os.environ["PATH"],
           "TERM": "xterm-256color", "LANG": "C.UTF-8", "SHELL": "/bin/sh",
           "INVERSE_LOG": str(inverse_log)}
    command = [TMUX, "-S", str(socket)]

    def tmux(*args, check=True):
        return subprocess.run(command + list(args), env=env, capture_output=True, check=check, text=True).stdout

    viewer_pane = "viewer:0.0"

    def pane(*args):
        return tmux("capture-pane", "-p", *args, "-t", viewer_pane)

    term = Terminal(TMUX, command[1:] + ["-f", str(tmux_cfg), "new-session", "-s", "viewer",
                                         "sleep 0.25; exec " + shlex.join([BINARY, "--listen", preview_socket,
                                               "--inverse-search", str(callback),
                                               "--inverse-search-resolver", str(resolver), PDF, "2"])], env)
    try:
        term.pump(1.8)
        viewer_pane = tmux("display-message", "-p", "-t", viewer_pane, "#{pane_id}").strip()
        assert PLACEHOLDER in pane() and "P2/5" in pane(), pane()
        assert UPLOAD in term.raw and PLACEHOLDER.encode() in term.raw
        assert b"\x1b[?2026h" in term.raw, "tmux did not synchronize redraws to the terminal"
        assert tmux("display-message", "-p", "-t", viewer_pane, "#{pane_title}").strip() == "live.pdf", \
            "the pane was not titled after the document"

        term.send("\x0c", 0.3)
        assert inverse_log.read_text() == PDF+":3:1", "Ctrl+L did not reach fancy-cat in tmux"
        inverse_log.unlink()
        term.send("\x1b[<16;50;10M", 0.2)
        assert not inverse_log.exists(), "tmux Ctrl+press triggered inverse lookup"
        term.send("\x1b[<16;50;10m", 0.3)
        assert inverse_log.read_text() == PDF+":3:1", "tmux swallowed Ctrl+click"

        term.send("J", 0.38)
        assert "P3/5" in pane(), pane()
        term.send("K", 0.38)
        assert "P2/5" in pane() and PLACEHOLDER in pane(), pane()
        term.send("/", 0.2)
        assert pane().splitlines()[-1].startswith("/"), "prompt was covered by a placeholder"
        term.send("quantum\r", 0.38)
        match_images = set(term.images)
        term.send("n", 0.6)
        assert "P3/5" in pane(), "next match did not move to page 3"
        assert term.images.keys() - match_images, "search did not show a marked strip"
        term.send("\x0f", 0.35)
        assert "P2/5" in pane(), "Ctrl+o did not return through tmux"
        term.send("\x1b[105;5u", 0.35)
        assert "P3/5" in pane(), "tmux mapped Ctrl+i to Tab"
        term.send("K", 0.35)
        assert "P2/5" in pane(), "expected page 2 before the scroll test"
        before = pane("-e")
        term.send(" ", 0.35)
        assert pane("-e") != before, "Space did not scroll"
        term.send("\x1b[32;2u", 0.35)
        assert pane("-e") == before, "tmux lost Shift+Space"

        # Grouped and spaced reports of one notch scroll alike; the opposite notch undoes it.
        down = "\x1b[<65;50;10M"
        up = "\x1b[<64;50;10M"
        term.send(down * 5, 0.2)
        after_wheel = pane("-e")
        assert after_wheel != before, "wheel reports did not scroll through tmux"
        term.send(up * 5, 0.2)
        assert pane("-e") == before, "the reverse wheel reports lost distance"
        for _ in range(5):
            term.send(down, 0.03)
        assert pane("-e") == after_wheel, "grouping the wheel changed the distance"

        # hxp runs the viewer in the right half of a shared tmux window.
        tmux("split-window", "-hb", "-t", viewer_pane, "sleep 30")
        tmux("select-pane", "-t", viewer_pane)
        term.pump(0.4)
        subprocess.run([BINARY, "--remote", preview_socket, "goto-page", "4", ""], env=env, check=True)
        term.pump(0.4)
        assert "P4/5" in pane() and PLACEHOLDER in pane(), "remote jump failed in an hxp-style split"
        staged = root / "replacement.pdf"
        shutil.copyfile(FIXTURE, staged)
        os.replace(staged, PDF)
        term.pump(0.5)
        assert "P4/5" in pane() and PLACEHOLDER in pane(), "atomic reload lost the tmux split preview"

        tmux("new-window", "-t", "viewer:1", "printf 'other window\\n'; sleep 10")
        term.pump(0.3)
        assert PLACEHOLDER not in tmux("capture-pane", "-p", "-t", "viewer:1.0")
        start = len(term.raw)
        tmux("select-window", "-t", "viewer:0")
        term.pump(0.6)
        assert UPLOAD in term.raw[start:] and PLACEHOLDER in pane(), "focus did not restore images"

        # Quitting restores the title of the program that opened the viewer (Yazi).
        opener = "printf '\\033]2;browser\\033\\\\'; " + shlex.join([BINARY, PDF]) + "; sleep 10"
        tmux("new-window", "-t", "viewer:2", opener)
        term.pump(0.8)
        title = lambda: tmux("display-message", "-p", "-t", "viewer:2", "#{pane_title}").strip()
        assert title() == "live.pdf", title()
        term.send("q", 0.4)
        assert title() == "browser", "quitting left the document title behind"
        tmux("select-window", "-t", "viewer:0")
        term.pump(0.6)

        tmux("detach-client", "-s", "viewer")
        term.pump(0.3)
        assert term.wait_exit() == 0, "detach did not return"
        other = Terminal(TMUX, command[1:] + ["attach", "-t", "viewer"], env)
        os.close(term.fd)
        term = other
        term.pump(0.8)
        assert UPLOAD in term.raw and PLACEHOLDER in pane(), "reattach did not send images to the new client"
        term.send("q", 0.32)
        assert not list(root.glob("tty-graphics-protocol-fancy-cat-*")), "tile files left after quit"
    finally:
        tmux("kill-server", check=False)
        os.close(term.fd)

print("PASS: real tmux graphics, input, hxp-style split and remote jump, reload, focus and reattach")
