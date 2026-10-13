# ETAF Weread manual

`M-x etaf-weread-open` replaces the selected window with the reader.  It does
not split the frame or defer to `display-buffer` rules; use `etaf-weread-view`
to embed the reader in another layout.

## Keys

| Key | Command |
| --- | --- |
| `↑` / `↓`, `C-n` / `C-p` | move the book selection |
| wheel | select a book, or scroll the detail/highlight pane over it |
| `RET`, double click | open the selected book (detail, or highlights in the notebook) |
| `v` | switch the side pane between detail and highlights |
| `C-v` / `M-v`, `SPC` / `S-SPC` | scroll the detail or highlight pane one page |
| `d` / `P` | show the detail pane / the highlights of the selected book |
| `RET` in `本地书` | open the selected local book's first chapter |
| `f` | reading-only layout: the open chapter owns the frame |
| `F` | cycle the reading font: small, medium (the frame's font), large |
| `a` | start or stop automatic reading (one line every few seconds) |
| `y` | look the selected text, or the reading line, up in the dictionary |
| `N` / `M` | jump to the next matched WeChat highlight / choose one from a list |
| `[` / `]` | narrow or widen the reading column (more or less inset) |
| `m` | cycle reading columns: automatic, 1, 2 … as many as fit |
| `↑` / `↓`, wheel | scroll the chapter line by line |
| `g` / `G` | top / end of the open chapter |
| `c` | jump to a chapter of the open local book |
| `b` / `B` | bookmark the reading place / jump to one of the book's bookmarks |
| `%` | jump to a percentage of the open local book |
| `/` | search inside the open book while reading (the store otherwise) |
| `w` | write the open local book's reading place back to the WeChat Reading account |
| `o` | open the selected book in the WeChat Reading web reader |
| `E` | export the selected book's highlights and thoughts as Markdown |
| `s` `n` `i` `t` `L` | shelf, notebook, local notes index, statistics, local books |
| `1`–`7` | the sidebar sections in order |
| `/` or `S` | search the WeChat Reading store |
| `I` | index the notebook's highlights into the local database |
| `g` | reload the current list, account and statistics |
| `T` | switch to the next palette (dark, light, sepia) |
| `C-c h` | key summary in the echo area |
| `q` | close the reader |

In the local index section the search field filters the indexed highlights
instead of the store, and `RET` opens the book of the selected highlight.

## Reading a local book

The `本地书` section lists every TXT, Markdown and EPUB file in
`etaf-weread-library-directory` (default `~/ebooks`).  Opening one reads the
file into chapters and starts reading:

- while a chapter is open the reading pane owns the frame's body: the book
  list steps aside and comes back when `v` leaves the text for the book card;
- the text is wrapped to `etaf-weread-reading-measure` columns and the column
  is centered, so a wide frame stays readable; `[` and `]` adjust the width
  while reading and the choice is remembered;
- a frame wide enough for more than one column shows as many as the pane
  holds (up to four) side by side; `m` cycles automatic, one column, two and
  so on, and the choice is remembered as well;
- Chinese paragraphs start with the two-character indent while the chapter
  heading stays flush, and the running head reports how far the book is read;
- `↑`/`↓` and the wheel scroll line by line, `C-v`/`M-v` and
  `SPC`/`S-SPC` scroll a page (both columns at once), `<next>`/`<prior>` turn
  to the next and previous chapter, `g`/`G` jump to its start and end, `c`
  picks a chapter from the book's own list, and `v` leaves the text for the
  book list;
- `a` reads for you: one line advances every
  `etaf-weread-auto-scroll-interval` seconds, the end of a chapter turns to
  the next one, and the last line of the book stops it; `a` again stops it
  earlier;
- `y` looks the selected text, or the line at the top of the visible chapter,
  up with `etaf-weread-dictionary-function` and shows the definition below the
  reader: a `youdao-dictionary` with its API key and secret configured wins,
  and otherwise the macOS system dictionaries answer offline, so a word in an
  English book is one key away;
- a local book can be bound to its account book (`bind set <file> <书名>`, or
  `bind auto --dir ~/ebooks`; with Pi, prefix the backend command with
  `pi-skill weread`): the reading head then shows
  the account progress beside the local one (`36% · 云端 12%`), the local book
  list shows the account progress as the row meter, and the binding pins which
  account book the highlights are matched from;
- `w` writes the reading place of the open local book back to the account.  The
  account endpoint needs the reader's own signature, so the `weread` skill
  drives the official web reader in the controlled browser; the action asks for
  confirmation first, reports the account reply in the status line, and the
  head updates to the number the account reported.  A local file without a
  binding tells you the `bind set` command instead of guessing;
- the account's highlights of the same book are matched to the local text
  (`etaf-weread-local-note-matching'): opening a book finds it in the notebook
  by title, keeps the highlights whose text the local edition shares, and
  paints those lines with a tinted bar; `N` jumps to the next one (wrapping)
  and `M` picks from the list, with the attached thought in the status line;
- opening a book reports how long it was read and how many of its chapters
  were opened (`etaf-weread-reading-stats'), so a long book shows its
  accumulated time instead of starting from zero every session;
- `F` cycles the reading font (small, medium, large); a scaled font shows
  fewer rows of the chapter, wraps the text again and shrinks the canvas so
  nothing is cut off at the bottom, and the choice is remembered (leaving the
  chapter with `v` restores the full-height frame);
- `f` gives the whole frame to the chapter (no navigation, hint or footer)
  and `f` again brings the reader back; `T` cycles the palette;
- the reading head names the book, the chapter number and the chapter title,
  and the file is read from disk, so the account and the backend stay
  untouched;
- `b` bookmarks the place (the same key removes it), `B` jumps between the
  book's bookmarks, `/` searches inside the book and jumps to a match, and
  `%` jumps to a percentage of it;
- reopening a book continues where the last session stopped: the chapter is
  restored exactly and the position inside it as a fraction, so a different
  frame size or reading width lands in the same place
  (`etaf-weread-remember-positions' turns it off);
- the reader also counts reading time and visited chapters per book
  (`etaf-weread-track-reading-time', default on), reports them in the status
  line when a book is opened, and keeps them in the settings file where
  `etaf-weread-reading-stats' returns them.

Only files the person already holds are read; a WeChat Reading title whose text
lives behind the site's reader still opens in the browser with `o`.

The chosen palette and reading width are stored in
`etaf-weread-settings-file` (default
`<user-emacs-directory>/etaf-weread/settings.eld`), so the next session starts
with them; a corrupt or unreadable file falls back to the defaults.

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

## List cache and background refresh

Every sidebar list is cached under its own key (a search keys on its keyword).
Opening a section shows the cached rows at once and compares them with a fresh
reply in the background, so a section switch never waits for the network; a
reply that differs repaints the list, and one that did not change leaves the
reader exactly where it is (no loading flash, no reset selection).

While the reader is idle, one list at a time is warmed or refreshed in the
background, so opening a section the account has not visited yet is usually
instant.  The warmer pauses while the reader's buffer is not on screen, backs
off after a failure and stops altogether when the account needs a human (an
expired login), resuming after the next successful load. `etaf-weread-library-refresh-interval` (default 120 seconds) is how
old a cache may be before the timer refreshes it — lower it for a more current
sidebar, raise it for fewer requests; set `etaf-weread-prefetch-lists` to nil
to keep the cache to the sections you actually open, or change
`etaf-weread-prefetch-interval` (default 15 seconds) to control how often the
timer looks for work. `g` refreshes the current section in the foreground.

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

`etaf-weread-theme-mode` selects the `dark`, `light` or `sepia` palette; `T`
switches a mounted reader, which repaints every surface with the new palette.
Views use `etaf-weread-color` and the ETAF UI controls in the subtree follow
`etaf-weread-theme-defaults`, so every palette shares one layout and the reader
renders the same surface in every Emacs theme.  `etaf-weread-cycle-theme`
performs the switch for a scripted or headless session; a mounted caller
replaces the view afterwards, which is what the key does.

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

- **登录态失效**: the status line shows the backend message; sign in again
  through the backend (README, "The `weread` backend": `login --from-chrome` or
  `--cookie`, or `pi-skill weread login` with Pi) and press `g`.
- **Empty shelf or notebook**: run the backend `status` (same section); a
  failing backend reply is reported in the status line, and the reader stays
  usable.
- **The local index is not written**: Emacs must be built with SQLite support
  (`sqlite-available-p`); otherwise the index section reports the storage
  failure while the online reader keeps working.
- **A book's detail does not appear**: the detail pane waits for quiet before
  following the selection; press `RET` or `d` to load it immediately.
