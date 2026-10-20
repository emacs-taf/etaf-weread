# Changelog

All notable user-visible changes to ETAF Weread.

## Unreleased

- `M-x etaf-weread-login` signs in (or refreshes) the account through the
  bundled backend — a signed-in controlled browser, the local Chrome session or
  a QR scan — and reloads the account, lists and statistics.  `M-x
  etaf-weread-logout` deletes the stored login and clears the account data from
  the reader without touching the WeChat Reading account.  A missing or expired
  login now reports `M-x etaf-weread-login` in the status line instead of the
  backend's command line, and the bundled backend gains a `logout` command.

- The reader opens as an ETAF application: its keys are root keys of the
  View, so RET reaches a focused control before it opens the selection, the
  canvas follows the palette, and the layout follows each settled resize
  without a reader-owned resize hook. It requires ETAF 0.3.0 and ETAF UI 0.2.0.

- `etaf-weread-mode-map` is removed. The reader's keys are declared on its root
  View; `C-c h` lists them. Keys the reader does not declare fall through to
  your own bindings, so bind an extra command globally instead.

- Installing from the package archive now compiles every module: the entry
  resolves its `lisp/` directory from the file being compiled, so an
  installation started from a script cannot point the compiler at the script's
  own directory.

- The WeChat Reading account backend now ships inside this package under
  `backends/weread/` and no longer needs a Pi skill, `pi-skill`, or a separate
  clone. Install `node` and sign in once through the bundled script. The
  login, bindings, config and export defaults moved to
  `~/.local/share/etaf-weread/` (or `$XDG_DATA_HOME/etaf-weread/`, or
  `$ETAF_WEREAD_HOME`); move an existing `~/.pi/agent/local/skills/weread/`
  there once to keep the login and bindings. `etaf-weread-skill-directory`
  became `etaf-weread-backend-directory`, and `etaf-weread-doctor` reports
  Node.js and the bundled script. The controlled browser used by `w` and by
  browser login is an optional external capability: set `WEREAD_CDP_CHANNEL`.

- `?` and `C-c h` now open the same searchable, read-only help dialog inside
  the reader. Effective bindings supply its labels; Escape or an outside
  click closes it and restores focus without splitting the window.

- Opening the minibuffer (`M-x`, a completion popup or the reader's own
  prompts) no longer shrinks the book list, the reading pane or the pane
  budgets to the lines the prompt borrows. The reader keeps the layout it
  committed for the window and returns to the full view unchanged once the
  prompt closes.

- Sidebar lists are shown from the session cache at once and compared with a
  fresh reply in the background: an unchanged list never repaints or resets
  the reader's place, and a mounted reader warms and refreshes one list at a
  time while idle (`etaf-weread-library-refresh-interval`, default 120
  seconds; `etaf-weread-prefetch-lists` and `etaf-weread-prefetch-interval`
  control the timer).

- Local books can be bound to their WeChat Reading account book
  (`bind set`, or `bind auto --dir ~/ebooks`): the reading head
  shows the account progress beside the local one, the local list shows it as
  the row meter, and the highlights of the bound book are matched without a
  title guess.
- `w` writes the reading place of the open local book back to the account; the
  bundled backend drives the official web reader for it because the account
  endpoint needs the reader's own signature.  The action confirms first and
  reports the account reply in the status line.

- Local reading is a reading mode of its own: an open chapter takes the frame
  body, its text sits in centered columns (as many as the pane holds, up to
  four, or a pinned count via `m`), `[` and `]` adjust the width, `f` turns the
  whole frame into reading surface, `T` cycles dark/light/sepia, paragraphs are
  indented the way Chinese books print them, and the running head shows how
  far the book is read.
- Reading keys: the arrows and the wheel scroll line by line, `g`/`G`
  jump to the start and end of the chapter, `c` picks a chapter from the
  book's own list, and `v` returns to the book list.
- Reading preferences (palette, column width, one or two columns, font size)
  are stored in `etaf-weread-settings-file` and restored by the next session;
  `F` cycles the reading font between small, the frame's own font and large,
  and the row budget follows the chosen size.
- Reading inside a local book has bookmarks (`b`, `B`), an in-book search
  (`/`) that lists every occurrence and jumps to the chosen one, and a
  percentage jump (`%`) that lands where the progress bar promises.
- `a` turns on automatic reading: one line advances every
  `etaf-weread-auto-scroll-interval` seconds, the next chapter follows the
  current one, and the end of the book stops it.
- `y` looks the selected text or the reading line up and shows the definition
  below the reader: `youdao-dictionary` when its API credentials are set,
  otherwise the macOS system dictionaries, through the replaceable
  `etaf-weread-dictionary-function`.
- The account's WeChat Reading highlights are matched to the open local book
  by title and text, and the shared passages are painted on the local lines;
  `N` walks the matches, `M` picks one, and the attached thought is reported.
  `etaf-weread-local-note-matching` turns the overlay off.
- A local book keeps its reading time and visited chapters in the settings
  file (`etaf-weread-track-reading-time`); the status line reports them when
  the book is opened and `etaf-weread-reading-stats' returns them.
- A local book reopens where the last session stopped: the chapter is
  restored exactly and the position inside it as a fraction, so it survives
  a different frame size or reading width.
- First complete reader: shelf with all/reading/finished filters, notebook,
  book detail with table of contents, highlights grouped by chapter, store
  search, reading statistics, Markdown export and opening a book in the web
  reader.
- Local SQLite index of highlights through ETAF DB: reading a book stores its
  highlights, `笔记检索` searches the whole notebook offline, and `I` walks the
  notebook in the background (prefix argument re-fetches indexed books).
- Two palettes with one key and `:ui-*` tokens for the shared ETAF UI controls.
- Wide, medium and narrow layouts; the detail pane follows the selection after
  a short quiet period so fast browsing does not query every passed book.
- A reader session is headless: no buffer, no timer, a scripted client is a
  complete backend.

## 0.1.0

- Initial package skeleton: entry, theme, backend client, reader model, views
  and application shell.
