"""Exercise the preview socket and both SyncTeX directions with a real PDF."""
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from harness import Viewer, ROWS, YPIX

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="fancy-preview-") as directory:
    root = Path(directory)
    tex = root / "two pages.tex"
    tex.write_text(r"""\documentclass{article}
\begin{document}
First page.
\newpage
Second page.
\end{document}
""")
    subprocess.run(["pdflatex", "-synctex=1", "-interaction=batchmode", tex.name],
                   cwd=root, check=True, stdout=subprocess.DEVNULL)
    pdf = tex.with_suffix(".pdf")
    sock = str(root / "preview.sock")
    location = root / "location"
    callback = root / "editor callback"
    callback.write_text('#!/bin/sh\n[ "$#" = 1 ] && printf "%s" "$1" > "$LOCATION"\n')
    callback.chmod(0o700)
    tools = root / "bin"
    tools.mkdir()
    synctex_log = root / "synctex.log"
    synctex = tools / "synctex"
    synctex.write_text('#!/bin/sh\nprintf "lookup\\n" >> "$SYNCTEX_LOG"\nexec '
                       + shlex.quote(shutil.which("synctex")) + ' "$@"\n')
    synctex.chmod(0o700)
    config = root / "fancy-cat/config.json"
    config.parent.mkdir()
    config.write_text(json.dumps({"StatusBar": {"enabled": True, "items": ["P<page>/<total_pages>"]},
                                 "General": {"remember_page": False, "trim_margins": False,
                                             "timeout": 0.75, "retry_delay": 0.03,
                                             "zoom_min": 0.1, "detect_dpi": False},
                                 "FileMonitor": {"enabled": True, "latency": 0.03}}))
    env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=directory, LOCATION=str(location),
               TERM="xterm-256color", PATH=str(tools) + os.pathsep + os.environ["PATH"],
               SYNCTEX_LOG=str(synctex_log))
    v = Viewer(binary, ["--listen", sock, "--inverse-search", str(callback), str(pdf)], env,
               pixel_mouse=True)

    def remote(*args, wait=0.4):
        subprocess.run([binary, "--remote", sock, *args], check=True)
        v.pump(wait)

    try:
        v.pump(2)
        remote("goto-page", "2", "Second page")
        assert v.line(ROWS - 1).strip() == "P2/2"
        assert any(len(data) == 4*w*h for w, h, data in v.images.values()), "missing highlight"
        remote("forward-search", str(tex), "3", "1")
        assert v.line(ROWS - 1).strip() == "P1/2"
        v.send("\x1b[<16;501;301M\x1b[<16;501;301m", 0.5)
        source, line, column = location.read_text().rsplit(":", 2)
        assert Path(source).resolve() == tex and int(line) == 3 and int(column) >= 1

        # In a narrow split or at low zoom, the last page is shorter than the
        # viewport. Forward focus must still centre that page's source location.
        v.send(":40%\r", 0.3)
        remote("goto-page", "2", "Second page")
        highlight_y = [
            row * (YPIX // ROWS) + dy + height / 2
            for (image, _), (row, _, _, dy, _, _, _, height) in v.placements.items()
            if len(v.images[image][2]) == 4 * v.images[image][0] * v.images[image][1]
        ]
        assert highlight_y and all(abs(y - (YPIX - YPIX // ROWS) / 2) < YPIX // ROWS
                                   for y in highlight_y), "short-page highlight was not centred"
        remote("forward-search", str(tex), "5", "1")
        v.send("\x0c", 0.4)
        source, line, column = location.read_text().rsplit(":", 2)
        assert Path(source).resolve() == tex and int(line) == 5, "short-page focus jumped to the previous page"
        v.send("s", 0.3)

        before = synctex_log.read_text().count("lookup\n")
        os.kill(v.pid, signal.SIGSTOP)
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sender:
                for line in ("5", "3", "5"):
                    sender.sendto("\0".join(("forward-search", str(tex), line, "1")).encode(), sock)
        finally:
            os.kill(v.pid, signal.SIGCONT)
        v.pump(0.6)
        lookups = synctex_log.read_text().count("lookup\n") - before
        assert v.line(ROWS - 1).strip() == "P2/2", "burst missed the final source position"
        assert lookups == 1, f"queued navigation ran {lookups} SyncTeX lookups"

        updated = root / "updated.tex"
        updated.write_text(tex.read_text().replace("Second page.", "Second page.\n\\newpage\nThird page."))
        subprocess.run(["pdflatex", "-synctex=1", "-interaction=batchmode", updated.name],
                       cwd=root, check=True, stdout=subprocess.DEVNULL)
        # The compiler has not published its new output when hxp requests page 3.
        pdf.write_bytes(b"")
        remote("goto-page", "1", "First page", wait=0.1)
        remote("goto-page", "3", "Third page", wait=0.1)
        os.replace(updated.with_suffix(".pdf"), pdf)
        v.pump(0.8)
        assert v.line(ROWS - 1).strip() == "P3/3", "preview command was lost during a PDF reload"

        # A failed build must expire a deferred jump, rather than applying it later.
        saved_pdf = pdf.read_bytes()
        pdf.write_bytes(b"")
        remote("goto-page", "2", wait=0.1)
        v.pump(0.9)
        assert "Could not reload PDF" in v.text(), v.text()
        pdf.write_bytes(saved_pdf)
        v.pump(0.6)
        assert v.line(ROWS - 1).strip() == "P3/3", "failed reload retained a stale navigation command"
    finally:
        v.send("q", 0.2)
        assert v.wait_exit() == 0
        os.close(v.fd)
    assert not os.path.exists(sock)
print("PASS: remote search, burst coalescing, reload races and timeout, inverse callback, socket cleanup")
