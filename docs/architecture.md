# ETAF Weread architecture

## Modules

| File | Responsibility |
| --- | --- |
| `etaf-weread.el` | Package entry: the public API inventory and the feature closure. |
| `lisp/etaf-weread-theme.el` | Palettes, `etaf-weread-color` and the ETAF UI theme tokens. |
| `lisp/etaf-weread-service.el` | Backend client: turns requests into `weread` skill command lines and decodes JSON replies. |
| `lisp/etaf-weread-model.el` | Session state, list/detail/highlight loading, selection, panes, layout fitting and the public actions. |
| `lisp/etaf-weread-index.el` | Local SQLite index: schema, Data Controller and storage primitives through ETAF DB. |
| `lisp/etaf-weread-library.el` | Local book library: directory scan and TXT, Markdown and EPUB parsing into backend-shaped chapters. |
| `lisp/etaf-weread-views.el` | Internal Components that take plain values and callbacks. |
| `lisp/etaf-weread-app.el` | The `etaf-weread-app` Component, the buffer, the keymap and the reader commands. |

Only the framework is used: the application never calls the renderer directly.
A window change adapts the layout through the model, and ETAF refits the canvas
of every mounted runtime once a resize settles; the reader holds no direct Ebox
or ECSS reference.

The layout breakpoints are derived, not chosen: the wide threshold is the
sidebar plus the pane plus the columns a full book row needs, so a frame can
never show three columns the list cannot render in (below it the medium layout
keeps a glyph rail and one pane at a time).  `etaf-weread--list-min-columns`
records how many columns a full row spends outside its title.

No row may be taller than the row height the page budget counted.  Chrome rows
use the frame's line height; the reading column may scale its text (see
Reading font), and then the model budgets the pitch that font really paints and
hands the renderer a shorter canvas (`etaf-weread--reader-canvas-lines`), so a
scaled chapter never paints past the window.  A row may be *shorter* than the
budget — a blank or Latin-only row does not reach the height a CJK row does —
so the invariant is "taller than the budget", not equality.
Fallback fonts are common offenders: a symbol can use Sarasa at 18px or Arial
Unicode at 19px, and a bold symbol can make the row taller still.  The reader
uses the shared `etaf-ui-icon' SVG set for its navigation, which is measured
against the line and never grows a row.

An active or selected state is carried by color, surface and weight, never by
a prefix glyph.  A `* `-style marker changes the label's width, so every
switch shifts the whole row or tab strip; the sidebar paints a tinted surface
with an accent edge, and the shared Tabs button uses its selected variant.
Validate with `etaf-weread-gui-check` in `scripts/weread-gui-probe.el`: the
canvas must fit the window, no row may exceed the budgeted row height, and
every line must fit the body width.

## Reading pane

A local book needs no backend: the section scans
`etaf-weread-library-directory`, and opening a file publishes its chapter text
into the same side pane the card and the highlights use.  The model wraps the
chapter to `etaf-weread--pane-content-columns` before publishing, so the pane
counts and scrolls rows that are already the right width and no line is
clipped; `<next>`/`<prior>` turn chapters while that pane is shown.

## Reading font

The `small`, `medium` and `large` presets scale only the reading column.  The
engine converts CSS reference pixels to points before it resolves a font, and a
frame defines how many pixels a point is, so the nominal size is not the size
that gets painted; the model measures candidate sizes in the frame and keeps
the one whose resolved font is closest to the preset's target
(`etaf-weread--font-pixels-closest`).

The row height is not the nominal line height either: a line is as tall as the
tallest ascent plus the tallest descent of every font it uses, and a Chinese
book mixes the frame's Latin font with a CJK fallback that is often one pixel
taller.  `etaf-weread--font-line-pixels` probes both, the budget uses the
taller result, and the canvas line count shrinks with it
(`etaf-weread--reader-canvas-lines`), because the renderer plans its canvas in
frame line heights.  Leaving the chapter restores the full-height canvas.

## Local notes overlay

`etaf-weread-match-local-notes` matches the account's highlights to the open
local book.  A binding of the local file names the account book directly; only
without one is the notebook searched for the local title (normalised without
spaces and punctuation).  The best match's highlights are fetched, and each
highlight is kept only when its whitespace-free text appears in the local
chapters, so another edition contributes only the passages it shares.  The
matches live in the session's `:local-notes`, and the model marks the wrapped
lines they cover with `:note`, which the reading view paints with the accent
surface.  Matching is asynchronous like every backend action and runs when a
local book is opened (`etaf-weread-local-note-matching`).

## Account binding and progress write-back

The account book of a local file is owned by the `weread` skill
(`bindings.json` in its private data directory), not by the reader: the model
loads it through the ordinary `:bind` request and keeps the answer in
`:local-bindings`.  Each entry carries the account book id, its title, and the
account's progress; the model decorates the local rows with that percent and
`etaf-weread--cloud-progress` gives the reading head the number beside the
local one.  Nothing about the binding is cached across the skill's own file, so
a rebind is visible on the next load.

`etaf-weread-sync-progress` is the only write path.  After the reader confirms,
the model sends `:sync-progress` with the open file, its chapter title, the
local percent and `:yes`, and a wider `:timeout` because the skill drives the
controlled browser: the account's progress endpoint requires the official
reader's own signature, so a plain HTTP replay is silently dropped and the
skill opens the reader, jumps to the chapter and reads the account back.  The
reply's percent and chapter update the published binding, which is what the
head and the row meter show after a sync.  A file without a binding makes the
action signal before any request is sent.

## Data flow

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

## List cache and background refresh

Library lists are cached per session under a key that names the section (a
search keys on its keyword, so another keyword is another list).  Switching a
section paints the cache synchronously and then compares it with a fresh reply
in the background; the reply replaces the cache and repaints only when the rows
or the total differ, so an unchanged sidebar costs one request and no repaint.
The detail and highlight panes use the same idea per book id.

The policy itself lives in ETAF (`etaf-list-cache`), so the reader only maps
its sections to keys and requests: a cached entry carries its timestamp,
`etaf-weread-library-refresh-interval` is passed as the freshness, and the
timer armed on start (`etaf-weread-prefetch-interval`) asks for one candidate
at a time — the stalest list, or a list that was never loaded.  A background
load never sets the loading state, never bumps the list generation a visible
load owns, and is skipped while the reader is loading or has just opened;
`etaf-weread--dispose` disarms the cache.  The cache is a display shortcut
only: the backend reply is still the source of truth, and the skill stays a
thin data layer (no caching there).

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
