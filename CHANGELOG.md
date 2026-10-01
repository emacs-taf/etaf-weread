# Changelog

All notable user-visible changes to ETAF Weread.

## Unreleased

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
