"""Keyboard inverse search, Ctrl+click release and resolver protocol in a real viewer."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from harness import Viewer, ROWS

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='fancy-inverse-') as directory:
    root = Path(directory)
    source = root / 'source with spaces.typ'
    source.write_text('#set page(width: 16cm, height: 10cm, margin: 1cm)\n'
                      'A uniquely recognizable paragraph for source navigation.\n')
    pdf = source.with_suffix('.pdf')
    subprocess.run(['typst', 'compile', str(source), str(pdf)], check=True)
    callback = root / 'editor callback'
    callback.write_text('#!/bin/sh\nprintf "%s" "$1" > "$LOCATION"\n')
    callback.chmod(0o700)
    resolver = root / 'resolver'
    resolver.write_text('''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
Path(os.environ['LOOKUP']).write_text(json.dumps(sys.argv[1:]))
code=Path(os.environ['MODE']).read_text().strip()
if code=='invalid':
    print('not-a-source-location')
    sys.exit(0)
if code: sys.exit(int(code))
print(os.environ['SOURCE']+':2:1')
''')
    resolver.chmod(0o700)
    mode, location, lookup = root / 'mode', root / 'location', root / 'lookup'
    mode.write_text('')
    config = root / 'fancy-cat/config.json'
    config.parent.mkdir()
    base_config = {'StatusBar': {'enabled': True, 'items': ['P<page>/<total_pages>']},
                   'General': {'remember_page': False, 'trim_margins': False},
                   'FileMonitor': {'enabled': False}}
    config.write_text(json.dumps(base_config))
    env = dict(os.environ, HOME=directory, XDG_CONFIG_HOME=directory,
               XDG_STATE_HOME=str(root/'state'), TERM='xterm-256color',
               LOCATION=str(location), LOOKUP=str(lookup), MODE=str(mode), SOURCE=str(source))

    def viewer():
        v = Viewer(binary, ['--inverse-search', str(callback), '--inverse-search-resolver',
                            str(resolver), str(pdf)], env, pixel_mouse=True)
        v.pump(1.3)
        return v

    v = viewer()
    try:
        v.send('\x0c', 0.3)
        assert location.read_text() == str(source)+':2:1', v.line(ROWS-1)
        centre = json.loads(lookup.read_text())
        assert centre[0] == str(pdf) and centre[1] == '1'
        assert 'uniquely recognizable paragraph' in centre[4], centre
        location.unlink()
        v.send('d', 0.3)
        v.send('\x0c', 0.3)
        assert location.exists(), 'spread gutter prevented keyboard inverse search'
        v.send('d', 0.3)
        location.unlink()
        v.send('\x1b[<35;101;121M', 0.1)  # Pointer motion is recorded, even without redraw.
        v.send('\x0c', 0.3)
        pointer = json.loads(lookup.read_text())
        assert pointer[2:4] != centre[2:4], (pointer, centre)
        assert location.exists(), v.line(ROWS-1)
        location.unlink()
        v.send('\x1b[<16;101;121M', 0.15)
        assert not location.exists(), 'Ctrl+press fired before release'
        v.send('\x1b[<0;101;121m', 0.3)  # Ctrl may be released before the mouse button.
        assert location.exists(), 'release without held Ctrl did not trigger lookup'
        location.unlink()
        mode.write_text('4')
        v.send('\x0c', 0.3)
        assert 'AmbiguousSourceText' in v.line(ROWS-1), v.line(ROWS-1)
        assert not location.exists(), 'ambiguous match opened an editor'
        mode.write_text('3')
        v.send('\x0c', 0.3)
        assert 'NoMatchingSourceText' in v.line(ROWS-1), v.line(ROWS-1)
        mode.write_text('6')
        v.send('\x0c', 0.3)
        assert 'NoSyncTeXSourceLocation' in v.line(ROWS-1), v.line(ROWS-1)
        mode.write_text('1')
        v.send('\x0c', 0.3)
        assert 'InverseSourceLookupFailed' in v.line(ROWS-1), v.line(ROWS-1)
        assert not location.exists(), 'failed lookup reached editor callback'
        mode.write_text('invalid')
        v.send('\x0c', 0.3)
        assert 'InvalidSourceLocation' in v.line(ROWS-1), v.line(ROWS-1)
        assert not location.exists(), 'malformed location reached editor callback'
    finally:
        v.send('q', 0.1)
        assert v.wait_exit() == 0
        os.close(v.fd)

    mode.write_text('')
    base_config['KeyMap'] = {'inverse_search': '<C-g>'}
    config.write_text(json.dumps(base_config))
    v = viewer()
    try:
        v.send('\x0c', 0.2)
        assert not location.exists(), 'remapping kept the default binding'
        v.send('\x07', 0.3)
        assert location.exists(), 'remapped inverse search did not run'
    finally:
        v.send('q', 0.1)
        assert v.wait_exit() == 0
        os.close(v.fd)
print('PASS: Ctrl+L, pointer tracking, release-only mouse lookup, resolver failures and remapping')
