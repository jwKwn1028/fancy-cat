"""Drive fancy-cat in a pseudo-terminal that answers like a Kitty-graphics
terminal, track the screen text, and save transmitted images as PNG."""
import base64
import fcntl
import os
import pty
import re
import select
import struct
import termios
import time
import zlib

ROWS, COLS, XPIX, YPIX = 30, 100, 1000, 600


def write_png(path, width, height, rgb):
    raw = b"".join(b"\x00" + rgb[y * width * 3:(y + 1) * width * 3] for y in range(height))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


class Viewer:
    def __init__(self, binary, args, env, *, pixel_mouse=False):
        self.cells = [[" "] * COLS for _ in range(ROWS)]
        self.r = self.c = 0
        self.raw = bytearray()
        self.pending = b""
        self.images = {}  # id -> (w, h, rgb)
        self.loading = None  # [id, w, h, b64 parts, format, compression]
        self.shown = None  # id of the last placed image
        self.placements = {}  # (id, p) -> (row, col, X, Y, x, y, w, h)
        self.transmits = 0
        self.pixel_mouse = pixel_mouse
        # Ignore an outer tmux; test_tmux starts its own.
        env = {k: v for k, v in env.items() if k not in ("TMUX", "TMUX_PANE")}
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, XPIX, YPIX))
            os.execve(binary, [binary] + args, env)
        self.pid, self.fd = pid, fd
        self.status = None

    def apc(self, body):
        if not body.startswith("G"):
            return
        head, _, data = body[1:].partition(";")
        keys = dict(kv.split("=", 1) for kv in head.split(",") if "=" in kv)
        if keys.get("a") == "q":
            os.write(self.fd, b"\x1b_Gi=%s;OK\x1b\\" % keys.get("i", "1").encode())
            return
        if keys.get("a") == "p":
            self.shown = int(keys["i"])
            k = lambda n: int(keys.get(n, "0"))
            self.placements[(k("i"), k("p"))] = (self.r, self.c, k("X"), k("Y"), k("x"), k("y"), k("w"), k("h"))
            return
        if keys.get("a") == "d":
            sel, i = keys.get("d", "a"), int(keys.get("i", "0"))
            if sel in ("i", "I"):
                placement = int(keys.get("p", "0"))
                if placement:
                    self.placements.pop((i, placement), None)
                else:
                    self.placements = {key: v for key, v in self.placements.items() if key[0] != i}
                if sel == "I" and not any(image == i for image, _ in self.placements):
                    self.images.pop(i, None)
            elif sel in ("a", "A"):
                self.placements.clear()
            return
        if "f" in keys:
            self.loading = [int(keys["i"]), int(keys["s"]), int(keys["v"]), [data],
                            int(keys["f"]), keys.get("o")]
        elif self.loading is not None:
            self.loading[3].append(data)
        if self.loading is not None and keys.get("m", "0") == "0":
            i, w, h, parts, pixel_format, compression = self.loading
            pixels = base64.b64decode("".join(parts))
            if compression == "z":
                pixels = zlib.decompress(pixels)
            assert len(pixels) == w * h * (pixel_format // 8)
            self.images[i] = (w, h, pixels)
            self.loading = None
            self.transmits += 1

    def csi(self, params, final):
        if final == "p" and params == "?1016$" and self.pixel_mouse:
            os.write(self.fd, b"\x1b[?1016;2$y")
        elif final == "H":
            parts = [p for p in params.split(";")] if params else []
            self.r = int(parts[0]) - 1 if parts and parts[0] else 0
            self.c = int(parts[1]) - 1 if len(parts) > 1 and parts[1] else 0
        elif final == "C":
            self.c += int(params or 1)
        elif final == "J" and params in ("2", "3"):
            self.cells = [[" "] * COLS for _ in range(ROWS)]
        elif final == "c" and not params.startswith(">"):
            os.write(self.fd, b"\x1b[?62;4c")
        elif final == "n" and params == "5":
            os.write(self.fd, b"\x1b[0n")
        elif final == "n" and params == "6":
            os.write(self.fd, b"\x1b[%d;%dR" % (self.r + 1, self.c + 1))

    def feed(self, data):
        self.raw += data
        text = (self.pending + data).decode("utf-8", errors="replace")
        self.pending = b""
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "\x1b":
                if i + 1 >= len(text):
                    self.pending = text[i:].encode()
                    return
                kind = text[i + 1]
                if kind == "[":
                    m = re.compile(r"\x1b\[([0-9;:?<>=$ ]*)([@-~])").match(text, i)
                    if not m:
                        self.pending = text[i:].encode()
                        return
                    self.csi(m.group(1), m.group(2))
                    i = m.end()
                elif kind in "]_P^X":
                    end = text.find("\x1b\\", i + 2)
                    bel = text.find("\x07", i + 2) if kind == "]" else -1
                    if bel != -1 and (end == -1 or bel < end):
                        i = bel + 1
                        continue
                    if end == -1:
                        self.pending = text[i:].encode()
                        return
                    if kind == "_":
                        self.apc(text[i + 2:end])
                    i = end + 2
                else:
                    i += 2
            elif ch == "\r":
                self.c = 0
                i += 1
            elif ch == "\n":
                self.r += 1
                i += 1
            elif ord(ch) < 0x20:
                i += 1
            else:
                if 0 <= self.r < ROWS and 0 <= self.c < COLS:
                    self.cells[self.r][self.c] = ch
                self.c += 1
                i += 1

    def pump(self, seconds):
        deadline = time.time() + seconds
        while True:
            left = deadline - time.time()
            if left <= 0:
                return
            ready, _, _ = select.select([self.fd], [], [], left)
            if not ready:
                continue
            try:
                data = os.read(self.fd, 1 << 20)
            except OSError:
                return
            if not data:
                return
            self.feed(data)

    def send(self, keys, wait=0.5):
        os.write(self.fd, keys.encode() if isinstance(keys, str) else keys)
        self.pump(wait)

    def line(self, row):
        return "".join(self.cells[row]).rstrip()

    def text(self):
        return "\n".join(self.line(r) for r in range(ROWS))

    def save(self, path):
        if self.shown not in self.images:
            return None
        w, h, rgb = self.images[self.shown]
        write_png(path, w, h, rgb)
        return (w, h)

    def compose(self, path, cw=XPIX // COLS, ch=YPIX // ROWS):
        """Draws every placement onto a screen-sized canvas (dark background)."""
        W, H = COLS * cw, ROWS * ch
        canvas = bytearray(b"\x20\x20\x28" * (W * H))
        for (i, _), (r, c, X, Y, x, y, w, h) in self.placements.items():
            if i not in self.images:
                continue
            iw, ih, rgb = self.images[i]
            w = w or iw - x
            h = h or ih - y
            dx, dy = c * cw + X, r * ch + Y
            for row in range(h):
                ty = dy + row
                if not 0 <= ty < H:
                    continue
                src = ((y + row) * iw + x) * 3
                n = min(w, W - dx)
                if n > 0:
                    canvas[(ty * W + dx) * 3:(ty * W + dx + n) * 3] = rgb[src:src + n * 3]
        if path:
            write_png(path, W, H, bytes(canvas))
        return bytes(canvas)

    def wait_exit(self, seconds=5):
        deadline = time.time() + seconds
        while time.time() < deadline:
            self.pump(0.1)
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = status
                return status
        return None
