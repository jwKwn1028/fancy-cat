# Commands

These are the commands that can be executed:

- `:q` — quit
- `:<number>%` — set zoom level
- `:<number>` — go to page number
- `:x+<number>` / `:x-<number>` — scroll right (`+`) or left (`-`) by the given amount (e.g. `:x+10.5`)
- `:y+<number>` / `:y-<number>` — scroll up (`+`) or down (`-`) by the given amount (e.g. `:y-3.1`)

## Editor preview integration

Launch the viewer in a graphics-capable terminal or tmux pane. Use a unique
socket path inside a private directory for each preview session. For example:

```sh
session=$(mktemp -d)
fancy-cat --listen "$session/view.sock" --inverse-search hxp-jump document.pdf
```

From the editor process, pass the socket path for that session:

```sh
fancy-cat --remote "$session/view.sock" reload
fancy-cat --remote "$session/view.sock" goto-page 4 "phrase on page four"
fancy-cat --remote "$session/view.sock" forward-search "$PWD/document.tex" 28 1
```

`reload` checks for a published PDF immediately, even with polling disabled.
Unchanged files are skipped and queued navigation is preserved. Polling remains
the fallback.

Pages and lines start at one. The phrase and column are optional. A page jump
stays on its requested page if the phrase is absent. Forward search uses the
`synctex` executable and the open PDF's SyncTeX sidecar. For Markdown, send
the generated TeX path and mapped line. For Typst, send the page and phrase.

Ctrl+left-click resolves the clicked PDF point with SyncTeX and invokes the
configured executable with one argument, `file:line:column`. An unknown column
defaults to one. The callback and socket can be enabled independently.
The client exits successfully once its command is queued. Lookup failures
appear in the viewer. The viewer removes its socket on normal exit. A launcher
should remove its private session directory after the viewer exits.
