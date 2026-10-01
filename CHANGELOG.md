# Changelog

All notable user-visible changes to ETAF Weread.

## Unreleased

- Local reading is a reading mode of its own: an open chapter takes the frame
  body, its text sits in centered columns (as many as the pane holds, up to
  four, or a pinned count via `m`), `[` and `]` adjust the width, `f` turns the
  whole frame into reading surface, `T` cycles dark/light/sepia, paragraphs are
  indented the way Chinese books print them, and the running head shows how
  far the book is read.
- Reading keys: `j`/`k`, the arrows and the wheel scroll line by line, `g`/`G`
  jump to the start and end of the chapter, `c` picks a chapter from the
  book's own list, and `v` returns to the book list.
- Reading preferences (palette, column width, one or two columns) are stored
  in `etaf-weread-settings-file` and restored by the next session.
- Reading inside a local book has bookmarks (`b`, `B`), an in-book search
  (`/`) that lists every occurrence and jumps to the chosen one, and a
  percentage jump (`%`) that lands where the progress bar promises.
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
