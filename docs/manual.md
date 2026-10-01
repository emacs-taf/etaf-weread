# ETAF Weread manual

## Keys

| Key | Command |
| --- | --- |
| `j` / `k`, `C-n` / `C-p`, arrows | move the book selection |
| wheel | select a book, or scroll the detail/highlight pane over it |
| `RET`, double click | open the selected book (detail, or highlights in the notebook) |
| `v` | switch the side pane between detail and highlights |
| `C-v` / `M-v`, `SPC` / `S-SPC` | scroll the detail or highlight pane one page |
| `d` / `P` | show the detail pane / the highlights of the selected book |
| `o` | open the selected book in the WeChat Reading web reader |
| `E` | export the selected book's highlights and thoughts as Markdown |
| `s` `n` `i` `t` | shelf, notebook, local notes index, reading statistics |
| `1`–`7` | the sidebar sections in order |
| `/` or `S` | search the WeChat Reading store |
| `I` | index the notebook's highlights into the local database |
| `g` | reload the current list, account and statistics |
| `T` | switch between the dark and light palette |
| `?` | key summary in the echo area |
| `q` | close the reader |

In the local index section the search field filters the indexed highlights
instead of the store, and `RET` opens the book of the selected highlight.

## Sections

- **书架 / 全部书架** every book on the shelf with its progress and reading time.
- **在读 / 读完** the same list filtered by state.
- **笔记本** the books that have highlights or thoughts.
- **笔记检索** the local highlight index (see below).
- **搜索书城** store search results; the field accepts a book or author name.
- **阅读统计** finished/reading counts, total reading time, note count and the
  most-read books.

The detail pane follows the selection after `etaf-weread-detail-follow-delay`
seconds of quiet, so moving through the list quickly never asks the backend
about a book that was only passed over. Pressing `RET` loads it immediately.

## Local highlight index

WeChat Reading serves one book's highlights per request. The reader keeps its
own copy of everything it has seen in a SQLite database
(`etaf-weread-index-file`, default `~/.emacs.d/etaf-weread/notes.sqlite3`)
through ETAF DB:

- Reading a book's highlights stores them (`etaf-weread-index-on-read`, default
  on); a changed thought updates its stored row instead of adding another.
- `笔记检索` (or `etaf-weread-index-search`) filters the whole index by keyword
  across the quote, the thought, the chapter and the book title.
- `I` (`etaf-weread-index-notebook`) lists the notebook once and fetches the
  books that are not indexed yet, one at a time, reporting progress in the
  status line. `C-u I` re-fetches every notebook book, which is the way to
  refresh an index that was built from older data.

The index is a local copy, not the source of truth: the server still owns the
account and the skill owns the login.

## Theming

`etaf-weread-theme-mode` selects the `dark` or `light` palette; `T` switches a
mounted reader and repaints it. Views use `etaf-weread-color` and the ETAF UI
controls in the subtree follow `etaf-weread-theme-defaults`, so both palettes
share one layout and the reader renders the same surface in every Emacs theme.

## Scripting and custom backends

A session is headless:

```elisp
(let ((reader (etaf-weread-create :client #'my-client)))
  (etaf-weread-refresh reader)
  ...)
```

A client is a function of `(REQUEST CALLBACK)`; it answers through
`etaf-weread-client-call`'s protocol (`(:ok DATA)` or
`(:error MESSAGE :hint HINT)`) and may answer synchronously. Requests use
`:op` `:status`, `:shelf`, `:notebook`, `:book`, `:notes`, `:search`, `:stats`
or `:export`; `docs/architecture.md` describes the data shapes. Bind
`etaf-weread-client-factory` to change the backend of every new session, or
pass `:client` to `etaf-weread-create`. `examples/etaf-weread-demo.el` is a
complete scripted account in one function.

`etaf-weread-state` returns a detached snapshot for assertions or for rendering
outside ETAF.

## Troubleshooting

- **登录态失效**: the status line shows the skill message; run
  `pi-skill weread login` and press `g`.
- **Empty shelf or notebook**: check `pi-skill weread status`; a failing backend
  reply is reported in the status line, and the reader stays usable.
- **The local index is not written**: Emacs must be built with SQLite support
  (`sqlite-available-p`); otherwise the index section reports the storage
  failure while the online reader keeps working.
- **A book's detail does not appear**: the detail pane waits for quiet before
  following the selection; press `RET` or `d` to load it immediately.
