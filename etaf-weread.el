;;; etaf-weread.el --- WeChat Reading client for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0") (etaf-db "0.1.0"))
;; Keywords: hypermedia, ui
;; URL: https://gitea.vhkd.top/geekinney/etaf-weread

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-weread) after adding this repository
;; and the ETAF, ETAF UI, ETAF DB and Ebox roots to `load-path'.  The reader is
;; a WeChat Reading client for Emacs: it browses the signed-in account's shelf,
;; the notebook of books with highlights, per-book details with their table of
;; contents and reading progress, the store search and the aggregate reading
;; statistics, and it reads and exports the account's highlights and thoughts.
;; A local SQLite index of those highlights, built through ETAF DB, makes the
;; whole notebook searchable offline.
;;
;; A session is the unit of state.  `etaf-weread-create' builds one, the
;; actions below drive it asynchronously, `etaf-weread-state' reports it as
;; plain data, and `etaf-weread-app' or `etaf-weread-open' display it.  Every
;; displayed value is an ETAF reactive source, so a backend reply repaints the
;; mounted reader without a refresh call.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions, and
;; the manual contains workflows.
;;
;; Function: etaf-weread-open (&optional model)
;;;###autoload (autoload 'etaf-weread-open "etaf-weread" nil t)
;; Mount the reader in `etaf-weread-buffer-name' and return its buffer.
;; MODEL defaults to a session from `etaf-weread-create', so the reader opens on
;; the shelf with the account of the stored login.  A caller-provided MODEL
;; keeps its section, selection and loaded detail, and is revived when it was
;; displayed before.  The buffer gets `etaf-weread-mode-map' and hides its mode
;; line; closing the buffer releases the session's timers and pending requests,
;; so a later `etaf-weread-open' with the same MODEL works again.
;;
;; Function: etaf-weread-close ()
;;;###autoload (autoload 'etaf-weread-close "etaf-weread" nil t)
;; Unmount the reader and kill its buffer.
;; Unmounting releases the session's follow timer, its SQLite Data Controller
;; and its in-flight backend requests; the session itself stays usable for a
;; later mount.
;;
;; Function: etaf-weread-view (&optional model)
;;;###autoload (autoload 'etaf-weread-view "etaf-weread" nil t)
;; Return the reader View for MODEL, defaulting to a new session.
;; Use it to embed the reader in your own `etaf-mount' call, for example inside
;; a tab or a larger layout; `etaf-weread-open' is the shortcut that also owns
;; the buffer.
;;
;; Component: etaf-weread-app (&key model)
;; Render the mounted reader for MODEL and own its session lifecycle.
;; MODEL must come from `etaf-weread-create'.  Mounting provides the palette for
;; its subtree, fits the layout and loads the current section; unmounting
;; disposes the session.  The Component reads every displayed value from the
;; model, so any action or backend reply repaints it; prefer `etaf-weread-open'
;; or `etaf-weread-view' over mounting the Component directly.
;;
;; Function: etaf-weread-create (&key client)
;; Return a new reader session that talks to CLIENT.
;; CLIENT defaults to `etaf-weread-client-factory' when that is bound and
;; otherwise to `etaf-weread-make-client'.  The session owns no buffer and no
;; timer before it is mounted, so it is a complete headless reader for scripts
;; and tests.  Pass a CLIENT function to drive the same reader from another
;; backend.
;;
;; Function: etaf-weread-state (app)
;; Return APP's session state as a detached plist snapshot.
;; Keys are `:section', `:filter', `:title', `:subtitle', `:mode', `:query',
;; `:items', `:visible', `:window-start', `:selection', `:page-size',
;; `:rows-total', `:list-total', `:layout', `:pane', `:pane-rows',
;; `:pane-scroll', `:pane-total', `:detail', `:local' (the open local book),
;; `:reader-lines' (its wrapped chapter text), `:reader-title',
;; `:reader-measure' (the chosen column width), `:reader-font' (the chosen
;; font preset), `:reader-font-size' (its CSS pixel size, nil for the frame's
;; own font), `:reader-line-height' (one reading row in pixels),
;; `:reader-columns' (the width the open chapter is wrapped to), `:reader-rows'
;; (one column's height), `:reader-spread', `:reader-shown' (the columns on
;; screen), `:reader-progress' (percent read), `:zen', `:auto-scroll' (whether
;; the reader advances by itself), `:local-bindings' (the account binding of
;; the open local book and the account progress of every bound local book),
;; `:notes', `:stats', `:account',
;; `:summary', `:index-query', `:index-syncing', `:theme', `:loading',
;; `:error', `:message' and `:viewport-width' (the pixel canvas the reader
;; mounts into).  The snapshot copies every value, so mutating it never changes
;; the reader; use it to render outside ETAF or to assert behavior in tests.
;; `:rows-total' counts loaded rows; `:list-total' keeps the backend's total
;; when reported and otherwise equals the loaded count.
;;
;; Function: etaf-weread-refresh (app)
;; Reload APP's current list, account and statistics.
;; It re-fits the layout to the window that shows APP, so call it after a
;; resize.  Every request is asynchronous and a reply belonging to a superseded
;; load is dropped, which makes repeated refreshes safe.
;;
;; Function: etaf-weread-locate (app section)
;; Show SECTION of APP and load its rows.
;; SECTION is one of the keys in `etaf-weread-sections': `:shelf', `:reading',
;; `:finished', `:notebook', `:search', `:index' or `:stats'.  An unknown
;; SECTION signals `etaf-weread-error' and leaves APP unchanged.
;;
;; Function: etaf-weread-set-filter (app filter)
;; Show the shelf books matching FILTER.
;; FILTER is `all', `reading' or `finished'; the matching section is shown and
;; any other value signals `etaf-weread-error'.
;;
;; Function: etaf-weread-toggle-bookmark (app)
;;;###autoload (autoload 'etaf-weread-toggle-bookmark "etaf-weread" nil t)
;; Add or remove a bookmark at APP's reading place and return this book's
;; bookmarks, newest first.
;; A bookmark within a fiftieth of the current place counts as the same one, so
;; the same call removes what it added; the list lives in
;; `etaf-weread-settings-file' and at most two hundred bookmarks are kept.
;;
;; Function: etaf-weread-show-bookmark (app bookmark)
;;;###autoload (autoload 'etaf-weread-show-bookmark "etaf-weread" nil t)
;; Show BOOKMARK in APP and return the chapter it lands in.
;; The chapter is exact and the position inside it comes from the stored
;; fraction, so a bookmark survives a different frame size or reading width.
;;
;; Function: etaf-weread-jump-to-percent (app percent)
;;;###autoload (autoload 'etaf-weread-jump-to-percent "etaf-weread" nil t)
;; Move APP to PERCENT (0-100) of its open local book and return the chapter
;; shown, counting from 1.
;; The chapter covering PERCENT is shown and the position inside it follows the
;; rest of the percentage; a session without a local book signals
;; `etaf-weread-error'.
;;
;; Function: etaf-weread-search-local-book (app keyword)
;;;###autoload (autoload 'etaf-weread-search-local-book "etaf-weread" nil t)
;; Return APP's local book matches for KEYWORD, in reading order.
;; Each match is (:chapter INDEX :title TITLE :needle NEEDLE :text EXCERPT) with
;; INDEX counting from 0; an empty KEYWORD signals `etaf-weread-error', and at
;; most two hundred matches are returned.
;;
;; Function: etaf-weread-show-match (app match)
;;;###autoload (autoload 'etaf-weread-show-match "etaf-weread" nil t)
;; Show MATCH in APP, scroll until the match is on screen, and return the
;; chapter it lands in.
;;
;; Function: etaf-weread-match-local-notes (app &optional refresh)
;;;###autoload (autoload 'etaf-weread-match-local-notes "etaf-weread" nil t)
;; Match APP's account highlights to its open local book and return them.
;; A binding of the local file names the account book; without one the local
;; title is looked up in the notebook and the highlights of the best match are
;; kept when their text appears in the local chapters, so a different edition
;; only contributes the passages it shares.  The result is published as the
;; session state's `:local-notes' and holds `:book-id', `:title' and
;; `:notes', each note carrying `:id', `:chapter', `:text' and `:thought'.
;; REFRESH non-nil fetches again; the requests are asynchronous, so a nil
;; return means the reply has not arrived yet.  A session without an open
;; local book signals `etaf-weread-error'.
;;
;; Function: etaf-weread-show-local-note (app note)
;;;###autoload (autoload 'etaf-weread-show-local-note "etaf-weread" nil t)
;; Show NOTE in APP and return the chapter it lands in.
;; The chapter is read again and the view scrolls until the note's text is
;; visible; the thought attached to the highlight is reported in the status
;; line.  NOTE comes from `etaf-weread-match-local-notes'.
;;
;; Function: etaf-weread-next-local-note (app)
;;;###autoload (autoload 'etaf-weread-next-local-note "etaf-weread" nil t)
;; Show the next matched highlight after APP's reading place and return it.
;; The search wraps: after the last match it continues with the first one; a
;; session without matched highlights returns nil.
;;
;; Variable: etaf-weread-local-note-matching
;; Whether a local book shows the account's highlights of the same title,
;; default t.  Opening a local book looks for it in the notebook, fetches the
;; highlights of the best match and marks the lines they share with the local
;; text; the reader's `N' and `M' keys walk them.  Turn it off to keep local
;; reading entirely offline.
;;
;; Function: etaf-weread-search (app keyword)
;; Search the WeChat Reading store for KEYWORD and show the results.
;; The keyword is trimmed; a blank KEYWORD signals `etaf-weread-error' without
;; querying the backend.
;;
;; Function: etaf-weread-move-selection (app delta)
;; Move APP's list selection by DELTA rows and keep it inside the visible page.
;; Selection stops at the first and last row; moving past a page boundary
;; scrolls the page so the new selection stays visible.
;;
;; Function: etaf-weread-activate-selection (app)
;; Open the book APP's selection points at.
;; A book row shows its detail (or its highlights in the notebook section) and
;; does nothing on an empty list; an indexed highlight row opens the notes of
;; its book.
;;
;; Function: etaf-weread-press-row (app index)
;; Press list row INDEX (counting from 1): select it, or open it when it is the
;; selected row.  This is the gesture a click on a list row performs, which a
;; programmatic caller can use to follow the same sentence.  An out-of-range
;; INDEX signals `etaf-weread-error'.
;;
;; Function: etaf-weread-show-book (app item &optional pane)
;; Show the book ITEM in APP's side pane and load what is missing.
;; ITEM is a row or a book id.  PANE is `detail' (the default) or `notes'.  A
;; missing book id signals `etaf-weread-error'; cached data paints at once and
;; the rest loads in the background.
;;
;; Function: etaf-weread-show-pane (app pane)
;; Show PANE in APP and return it.
;; PANE is `detail' for the book card with its table of contents or `notes' for
;; the highlights and thoughts; any other value signals `etaf-weread-error'.  A
;; `wide' layout keeps every column visible, so there PANE is remembered
;; without removing anything; compact layouts show that single pane.
;;
;; Function: etaf-weread-toggle-pane (app)
;; Switch APP's side pane between the book detail and its highlights.
;;
;; Function: etaf-weread-scroll-pane (app delta)
;; Scroll APP's detail or highlight pane by DELTA rows.
;;
;; Function: etaf-weread-reader-url (item)
;; Return the WeChat Reading URL of ITEM, or nil.
;; ITEM is a book row or a book id; the backend's deep link is used when it has
;; one, and otherwise the id addresses the web reader.
;;
;; Function: etaf-weread-open-book (app &optional item)
;; Open ITEM, or APP's selected book, in the WeChat Reading web reader.
;; The browser opens through `browse-url', so the reader keeps running; a book
;; without a URL signals `etaf-weread-error'.
;;
;; Function: etaf-weread-export-notes (app &optional item)
;; Export the highlights and thoughts of ITEM, or the selected book, as Markdown.
;; The weread skill writes the file under its configured export directory and
;; the reply is reported in the status line; a book without an id signals
;; `etaf-weread-error'.
;;
;; Function: etaf-weread-index-database ()
;; Return the SQLite database descriptor of the local notes index.
;; The descriptor declares the `highlights' table used by
;; `etaf-weread-index-notebook' and `etaf-weread-index-search'; pass it to
;; ETAF DB directly to inspect or query the index, and change
;; `etaf-weread-index-file' to move the database.
;;
;; Function: etaf-weread-index-notebook (app &optional refresh)
;; Index the highlights of every notebook book into APP's local SQLite index.
;; The notebook is listed once and the books not indexed yet are fetched one at
;; a time, so the progress is reported in the status line and the reader stays
;; usable.  REFRESH non-nil re-fetches books that are already indexed.  Like
;; every backend action the requests are asynchronous; a reply after the
;; session was disposed is dropped.
;;
;; Function: etaf-weread-index-search (app &optional keyword)
;; Filter the local highlight index by KEYWORD and show the results.
;; KEYWORD matches the highlight, the thought and the book title
;; case-insensitively; nil or an empty keyword shows every indexed highlight.
;; The section `:index' is shown, so callers can also use `etaf-weread-locate'.
;;
;; Variable: etaf-weread-sections
;; Sidebar groups and their sections, as (GROUP-NAME (SECTION LABEL ICON) ...).
;; Rebind it before mounting a session to show a different catalog of sections;
;; each SECTION must also be accepted by `etaf-weread-locate'.
;;
;; Variable: etaf-weread-buffer-name
;; Buffer `etaf-weread-open' mounts the reader into.
;;
;; Variable: etaf-weread-mode-map
;; Keymap installed by `etaf-weread-open'.  It keeps Ebox's TAB focus cycling
;; and replaces the scrolling keys with reader commands.
;;
;; Variable: etaf-weread-page-size
;; Book rows shown at once.  `etaf-weread-open' replaces it with the count that
;; fits the window, so the default only applies to a headless session.
;;
;; Variable: etaf-weread-wide-columns
;; Frame width, in columns, that fits the sidebar, the book list and the detail
;; pane at the same time.  At or above this width the reader uses the `wide'
;; layout.
;;
;; Variable: etaf-weread-medium-columns
;; Frame width, in columns, that still fits a glyph-only section rail.  At or
;; above this width, but below `etaf-weread-wide-columns', the reader keeps the
;; rail and shows a single pane; below it the sections move into a header strip.
;;
;; Variable: etaf-weread-library-refresh-interval
;; Seconds after which a cached sidebar list is refreshed in the background,
;; default 120.
;; A cached list is shown at once when a section is opened and then compared
;; with a fresh reply; the interval decides when the idle timer refreshes it.
;; Lower it for a more current sidebar, raise it for fewer requests.
;;
;; Variable: etaf-weread-prefetch-lists
;; Whether a mounted reader warms and refreshes sidebar lists while idle,
;; default t.
;; One list at a time is loaded in the background, so opening a section that
;; was never visited can paint from the cache.  Nil keeps the cache to the
;; sections the reader actually opens.
;;
;; Variable: etaf-weread-prefetch-interval
;; Seconds between two background list refreshes while the reader is idle,
;; default 15.
;; The timer only looks for work at this rhythm; a list is refreshed when it
;; is older than `etaf-weread-library-refresh-interval`.
;;
;; Variable: etaf-weread-list-limit
;; Rows requested for one list load, default 200.  Backend totals stay distinct
;; from loaded counts when the reply is partial.
;;
;; Variable: etaf-weread-search-count
;; Book results requested for one store search, default 25.
;;
;; Variable: etaf-weread-detail-follow-delay
;; Seconds of quiet before the detail pane follows the list selection, default
;; 0.3.  Browsing faster than this never requests a book that was only passed
;; over.
;;
;; Variable: etaf-weread-theme-mode
;; Palette used by `etaf-weread-color' and `etaf-weread-theme-defaults':
;; `dark' (default), `light' or `sepia'.  A mounted reader replaces its view
;; when the session's `:theme' value changes, which is what the reader's T key
;; does, so every painted surface takes the new palette at once.
;;
;; Variable: etaf-weread-reading-measure
;; Width of one local reading column in columns, default 44.
;; A local chapter is wrapped to this many columns and the column is centered
;; in the reading pane, which is what keeps a wide frame readable; a window
;; that cannot hold it shrinks the column instead.  The reader's `[' and `]'
;; keys adjust it and the choice is stored in `etaf-weread-settings-file'.
;;
;; Variable: etaf-weread-reading-spread
;; Reading columns shown side by side, `auto' (the default) or 1 to 4.
;; `auto' shows as many columns of `etaf-weread-reading-measure' as the pane
;; can hold, up to four, and a pinned count falls back to what fits when the
;; frame cannot hold it; the session state's `:reader-shown' reports what is on
;; screen.  The reader's `m' key cycles the choice and it is stored in
;; `etaf-weread-settings-file'.
;;
;; Variable: etaf-weread-auto-scroll-interval
;; Seconds auto-scroll waits before advancing one reading line, default 6.
;; `etaf-weread-toggle-auto-scroll' starts and stops the timer, and the
;; reader's `a' key toggles it.
;;
;; Variable: etaf-weread-reading-font
;; Reading font preset of a local book, `medium' (the default), `small' or
;; `large'.
;; `medium' keeps the frame's own font; the other presets scale the reading
;; text and the number of rows that fit with it, so a larger font shows fewer
;; rows of the same chapter.  The reader's `F' key cycles the presets and the
;; choice is stored in `etaf-weread-settings-file'.
;;
;; Variable: etaf-weread-settings-file
;; File that stores the reading preferences between sessions, default
;; `<user-emacs-directory>/etaf-weread/settings.eld'.
;; It keeps the chosen appearance, the reading column width, the column count
;; and where reading stopped in each local book.  Bind it before creating a
;; session to keep several profiles apart; the session remembers the file it
;; was created with, including when writing.
;;
;; Variable: etaf-weread-remember-positions
;; Whether the reader returns to where each local book was left, default t.
;; The chapter is restored exactly and the position inside it is a fraction of
;; the chapter, so it survives a different frame size or reading width; at most
;; fifty books keep a position.
;;
;; Variable: etaf-weread-position-save-delay
;; Seconds of quiet before a scrolled position is stored, default 1.5.
;; A chapter change, leaving the reader and closing the session store it at once.
;;
;; Variable: etaf-weread-index-file
;; SQLite file of the local highlight index, default
;; `<user-emacs-directory>/etaf-weread/notes.sqlite3'.  Bind it before creating
;; a session to keep several accounts apart or to use a disposable database.
;;
;; Variable: etaf-weread-index-on-read
;; Whether reading a book's highlights stores them in the local index.  The
;; default t builds the index as the account browses; nil leaves the database
;; untouched until `etaf-weread-index-notebook' is called.
;;
;; Function: etaf-weread-color (key &optional mode)
;; Return the palette color for KEY, optionally reading MODE instead of
;; `etaf-weread-theme-mode'.
;; KEY is one of `:bg', `:panel', `:panel2', `:panel3', `:line', `:ink',
;; `:muted', `:dim', `:accent', `:accent-soft', `:gold', `:ok', `:warn',
;; `:danger', `:danger-bg', `:info', `:selected', `:meter', `:cover' or
;; `:quote'; an unknown KEY signals `etaf-weread-error'.  Views use it to stay
;; readable in both palettes.
;;
;; Function: etaf-weread-theme-defaults (&optional mode)
;; Return the `:ui-*' theme defaults of MODE as a property plist.
;; The list is what the mounted reader provides to the ETAF UI controls in its
;; subtree, so buttons, inputs and progress meters follow the same palette.
;;
;; Function: etaf-weread-open-local-book (app path)
;;;###autoload (autoload 'etaf-weread-open-local-book "etaf-weread" nil t)
;; Open the local book at PATH in APP's reading pane and return its chapter
;; count.  The file is read from disk, so no backend and no account is
;; involved; an unreadable or unsupported file signals `etaf-weread-error'.
;; While a chapter is open the reading pane owns the frame's body in every
;; layout, and `etaf-weread-toggle-pane' leaves it for the book card.  A book
;; with a stored position continues in that chapter and place.
;;
;; Function: etaf-weread-sync-progress (app)
;;;###autoload (autoload 'etaf-weread-sync-progress "etaf-weread" nil t)
;; Write APP's reading place of the open local book back to the account.
;; The account's copy is updated by the official web reader, which the weread
;; skill drives in the controlled browser because its progress endpoint needs
;; the reader's own signature; the call asks for confirmation first and
;; reports the account reply in the status line.  The reading head and the
;; local rows then show the refreshed account progress.  A local book without
;; a binding signals `etaf-weread-error'; the function returns non-nil when a
;; sync was requested.
;;
;; Function: etaf-weread-read-chapter (app index)
;;;###autoload (autoload 'etaf-weread-read-chapter "etaf-weread" nil t)
;; Show chapter INDEX (counting from 1) of APP's opened local book.
;; INDEX is clamped into range, a session without a local book does nothing,
;; and the chapter text replaces the side pane's content.
;;
;; Function: etaf-weread-toggle-zen (app)
;;;###autoload (autoload 'etaf-weread-toggle-zen "etaf-weread" nil t)
;; Toggle APP's reading-only layout and return the new value.
;; The reading-only layout hides the section navigation, the running hint and
;; the footer, so the open local chapter owns the frame; the reading column
;; keeps its width and stays centered.  A session that is not showing a local
;; chapter does nothing, because there is nothing to read in zen, and returns
;; nil.  The state belongs to the session, not to the settings file.
;;
;; Function: etaf-weread-toggle-auto-scroll (app)
;;;###autoload (autoload 'etaf-weread-toggle-auto-scroll "etaf-weread" nil t)
;; Start or stop APP's automatic reading and return the new value.
;; While it runs, one reading line is advanced every
;; `etaf-weread-auto-scroll-interval' seconds; the end of a chapter turns to
;; the next one, and the last line of the book stops it.  A session that is
;; not showing a local chapter does nothing and returns nil, because there is
;; nothing to scroll.
;;
;; Function: etaf-weread-lookup (app &optional query)
;;;###autoload (autoload 'etaf-weread-lookup "etaf-weread" nil t)
;; Look QUERY up with `etaf-weread-dictionary-function' and return the text.
;; QUERY defaults to the selected text, or while reading to the line at the
;; top of the visible chapter; `etaf-weread-error' signals when there is
;; nothing to look up or the backend is missing.
;;
;; Function: etaf-weread-youdao-lookup (query)
;;;###autoload (autoload 'etaf-weread-youdao-lookup "etaf-weread" nil t)
;; Show QUERY's entry from the `youdao-dictionary' package.
;; The package's API key and secret must be configured; a missing package
;; signals `etaf-weread-error' instead of breaking the reader.
;;
;; Function: etaf-weread-macos-lookup (query)
;;;###autoload (autoload 'etaf-weread-macos-lookup "etaf-weread" nil t)
;; Show QUERY's definition from the macOS system dictionaries.
;; The lookup reads the definition through the DictionaryServices framework,
;; so it uses whatever dictionaries the system has and needs no account; a
;; word the dictionaries do not know, or another system, signals
;; `etaf-weread-error'.
;;
;; Function: etaf-weread-default-lookup (query)
;;;###autoload (autoload 'etaf-weread-default-lookup "etaf-weread" nil t)
;; Show QUERY's definition with the best available backend.
;; A `youdao-dictionary' with credentials configured is used first; elsewhere
;; the macOS system dictionary serves the lookup, and a machine with neither
;; signals `etaf-weread-error'.
;;
;; Variable: etaf-weread-dictionary-function
;; Function of one string that shows a dictionary entry for it, defaulting to
;; `etaf-weread-default-lookup'.  Replace it to use another dictionary backend;
;; the reader's `y' key passes the selected text or the line at the top of the
;; visible chapter.
;;
;; Variable: etaf-weread-dictionary-buffer-name
;; Buffer the lookup backends display a definition in, default "*ETAF 词典*".
;; It opens below the reader without taking its focus.
;;
;; Function: etaf-weread-reading-stats (app &optional path)
;;;###autoload (autoload 'etaf-weread-reading-stats "etaf-weread" nil t)
;; Return how much APP has read PATH, or its open local book.
;; The value is a plist with `:path', `:seconds' (total reading time),
;; `:chapters' (the chapter indices opened, newest first) and `:at' (when it
;; was last read); a book without a record returns nil.  The record lives in
;; `etaf-weread-settings-file' and is collected while
;; `etaf-weread-track-reading-time' is non-nil.
;;
;; Variable: etaf-weread-track-reading-time
;; Whether the reader records how long and how far a local book was read,
;; default t.  The record holds the total seconds and the chapter indices
;; opened so far and is what `etaf-weread-reading-stats' reports; leaving the
;; reading pane or closing the reader flushes it.
;;
;; Function: etaf-weread-adjust-reading-measure (app delta)
;;;###autoload (autoload 'etaf-weread-adjust-reading-measure "etaf-weread" nil t)
;; Widen APP's reading column by DELTA columns and return its new width.
;; The width stays inside the readable range, an open chapter is wrapped again
;; so no line clips, and the choice is stored in `etaf-weread-settings-file'.
;;
;; Function: etaf-weread-toggle-reading-spread (app)
;;;###autoload (autoload 'etaf-weread-toggle-reading-spread "etaf-weread" nil t)
;; Show the next reading column count in APP and return the choice.
;; The order is `auto', then one column, two and so on up to what the pane can
;; hold, and back to `auto'; `:reader-shown' in the session state reports what
;; is on screen.  The choice is stored in `etaf-weread-settings-file'.
;;
;; Function: etaf-weread-set-reading-font (app font)
;;;###autoload (autoload 'etaf-weread-set-reading-font "etaf-weread" nil t)
;; Set APP's reading font preset to FONT and return it.
;; FONT is `small', `medium' or `large'; any other value signals
;; `etaf-weread-error' and leaves APP unchanged.  `medium' keeps the frame's
;; own font; a scaled preset changes both the text size and the row budget, so
;; the open chapter is wrapped again when the new size changes how many
;; columns fit.  The choice is stored in `etaf-weread-settings-file'.
;;
;; Function: etaf-weread-cycle-reading-font (app)
;;;###autoload (autoload 'etaf-weread-cycle-reading-font "etaf-weread" nil t)
;; Show the next reading font preset in APP and return the choice.
;; The order is `small', `medium', `large' and back to `small'; the choice is
;; stored in `etaf-weread-settings-file' so the next session starts with it.
;;
;; Function: etaf-weread-cycle-theme (app)
;;;###autoload (autoload 'etaf-weread-cycle-theme "etaf-weread" nil t)
;; Switch APP to the next appearance and return it.
;; The order is `dark', `light' then `sepia', and the choice is stored in
;; `etaf-weread-settings-file'.  The session's `:theme' value is updated so a
;; mounted view repaints; replacing the view of an already mounted buffer is
;; the caller's job, which is what the reader's T key does.
;;
;; Variable: etaf-weread-library-directory
;; Directory scanned for local books; see `etaf-weread-library-books'.
;;
;; Function: etaf-weread-library-books (&optional directory)
;;;###autoload (autoload 'etaf-weread-library-books "etaf-weread" nil nil)
;; Return every local book under DIRECTORY as plists.
;; Each plist is (:path :title :author :format :size); DIRECTORY defaults to
;; `etaf-weread-library-directory', and a missing directory returns nil.
;;
;; Function: etaf-weread-library-content (path)
;;;###autoload (autoload 'etaf-weread-library-content "etaf-weread" nil nil)
;; Read the local book at PATH and return (:title :author :format :chapters).
;; CHAPTERS is a list of (:title :text) in reading order, the shape a backend
;; book reply carries; an unreadable or unsupported file signals
;; `etaf-weread-error'.
;;
;; Function: etaf-weread-make-client (&key skill-directory node-program timeout)
;; Return a client that calls the `weread' backend of SKILL-DIRECTORY.
;; NODE-PROGRAM runs the backend script, and TIMEOUT is the seconds a request
;; may take before it fails.  Every argument defaults to the matching
;; `etaf-weread-' variable, and the returned client is usable with
;; `etaf-weread-client-call'.
;;
;; Variable: etaf-weread-client-factory
;; Function of no arguments returning the client of new sessions.
;; Bind it to drive `etaf-weread-create' with another backend, which is how the
;; acceptance scenarios read a scripted account without the network.
;;
;; Function: etaf-weread-client-call (client request callback)
;; Send REQUEST to CLIENT and call CALLBACK once with its reply.
;; REQUEST is a plist starting with `:op' (`:status', `:shelf', `:notebook',
;; `:book', `:notes', `:search', `:stats' or `:export').  CALLBACK receives
;; `(:ok DATA)' on success and `(:error MESSAGE :hint HINT)' on failure, at
;; most once.  A client that cannot answer calls it neither; a session that is
;; disposed by `etaf-weread-cancel' drops late replies.
;;
;; Function: etaf-weread-cancel (client)
;; Cancel CLIENT's pending requests and drop their late replies.
;;
;; Function: etaf-weread-format-duration (seconds)
;; Return SECONDS of reading time as a compact string such as \"1小时13分\".
;; Zero or missing time returns an empty string, so a row can omit the column.
;;
;; Function: etaf-weread-progress-bar (percent &optional width)
;; Return a text progress bar of WIDTH cells for PERCENT (0 to 100).
;; WIDTH defaults to 8; the filled part uses U+2588 and the remainder U+2591.
;;
;; Variable: etaf-weread-skill-directory
;; Directory of the `weread' backend scripts used by the default client.
;;
;; Variable: etaf-weread-node-program
;; Program used to run the backend's Node.js script.
;;
;; Variable: etaf-weread-request-timeout
;; Seconds a backend request may take before it fails with a timeout error.
;;
;; Variable: etaf-weread-export-directory
;; Directory `etaf-weread-export-notes' passes to the skill, or nil for the
;; skill's own configured default.
;;
;; Error: etaf-weread-error
;; Invalid reader operation, for example an unknown section, an empty search
;; keyword, a missing book id or an unknown pane.  Backend failures are
;; reported in the session's `:error' and `:message' instead of being signaled,
;; because they happen asynchronously while the reader stays usable.

;;; Code:

(eval-and-compile
  (let ((directory (file-name-directory (or load-file-name
                                            (bound-and-true-p byte-compile-current-file)
                                            buffer-file-name))))
    (add-to-list 'load-path (expand-file-name "lisp" directory))))

(require 'etaf-weread-theme)
(require 'etaf-weread-service)
(require 'etaf-weread-index)
(require 'etaf-weread-library)
(require 'etaf-weread-model)
(require 'etaf-weread-views)
(require 'etaf-weread-app)

(provide 'etaf-weread)
;;; etaf-weread.el ends here
