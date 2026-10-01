# ETAF Weread architecture

## Modules

| File | Responsibility |
| --- | --- |
| `etaf-weread.el` | Package entry: the public API inventory and the feature closure. |
| `lisp/etaf-weread-theme.el` | Palettes, `etaf-weread-color` and the ETAF UI theme tokens. |
| `lisp/etaf-weread-service.el` | Backend client: turns requests into `weread` skill command lines and decodes JSON replies. |
| `lisp/etaf-weread-model.el` | Session state, list/detail/highlight loading, selection, panes, layout fitting and the public actions. |
| `lisp/etaf-weread-index.el` | Local SQLite index: schema, Data Controller and storage primitives through ETAF DB. |
| `lisp/etaf-weread-views.el` | Internal Components that take plain values and callbacks. |
| `lisp/etaf-weread-app.el` | The `etaf-weread-app` Component, the buffer, the keymap and the reader commands. |

Only the framework is used: the application never calls the renderer directly.
A window change adapts the layout through the model, and ETAF refits the canvas
of every mounted runtime once a resize settles; the reader holds no direct Ebox
or ECSS reference.

## Data flow

```text
weread skill (JSON over stdout)
  → service: child process, decoded plist, (:ok ...) or (:error ...)
  → model: generation-guarded list/detail/notes loads write reactive refs
  → views: take plain values and callbacks
  → app: reads the refs once per render, calls the View components
  → ETAF runtime → renderer → buffer
```

- A session is the unit of state and has no buffer until mounted. Every mutable
  value is an `etaf-ref`, so a backend reply repaints the mounted reader
  without a refresh call.
- Replies carry a generation: a reply from a superseded list load, book or
  notes request is dropped (or cached without being painted), so switching
  sections while a request is in flight cannot paint stale data.
- Failures never signal through the actions. The service maps backend errors to
  `(:error MESSAGE :hint HINT)`, and the model records them in `:error` and
  `:message`, which the status bar shows while the reader stays usable.
- The detail pane follows the selection after a quiet period
  (`etaf-weread-detail-follow-delay`); each book's detail and highlights are
  cached per id, so revisiting is instant.

## Local index

`etaf-weread-index.el` owns one SQLite table (`highlights`) described by
`etaf-weread-index-database` and served by an `etaf-data-controller` over
`etaf-sqlite-source`. Storing a book's highlights issues one `upsert` per row,
which inserts new rows and updates changed thoughts in place; the notebook walk
never duplicates a row. The model owns the orchestration (which book to fetch
next, how the rows appear in the list) and the index module owns the storage,
so the storage is testable without the network and the backend conversation
stays in one place.

The index is a local copy for offline search. The server remains the authority
for the account, and the `weread` skill remains the authority for the login.

## Invariants

- The public API is exactly the root entry Commentary; everything below `lisp/`
  is internal.
- Views take plain values; only the `etaf-weread-app` Component reads reactive
  state, so a repaint has one owner.
- A session's timers, follow timer, SQLite controller and in-flight child
  processes are released on dispose; a reply after dispose is dropped.
- Layout, page size and pane budgets are derived from the window that shows the
  reader; a headless session keeps the `wide` layout.
