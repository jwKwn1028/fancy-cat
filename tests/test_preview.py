"""Exercise the preview socket and both SyncTeX directions with a real PDF."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from harness import Viewer, ROWS

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
    config = root / "fancy-cat/config.json"
    config.parent.mkdir()
    config.write_text(json.dumps({"StatusBar": {"enabled": True, "items": ["P<page>/<total_pages>"]},
                                 "General": {"remember_page": False, "trim_margins": False}}))
    env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=directory, LOCATION=str(location),
               TERM="xterm-256color")
    v = Viewer(binary, ["--listen", sock, "--inverse-search", str(callback), str(pdf)], env,
               pixel_mouse=True)

    def remote(*args):
        subprocess.run([binary, "--remote", sock, *args], check=True)
        v.pump(0.4)

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
    finally:
        v.send("q", 0.2)
        assert v.wait_exit() == 0
        os.close(v.fd)
    assert not os.path.exists(sock)
print("PASS: remote page and text focus, forward search, inverse callback, socket cleanup")
