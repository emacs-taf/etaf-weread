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
;; `:pane-scroll', `:pane-total', `:detail', `:notes', `:stats', `:account',
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
;; Sidebar groups and their sections, as (GROUP-NAME (SECTION LABEL GLYPH) ...).
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
;; Palette used by `etaf-weread-color' and `etaf-weread-theme-defaults': `dark'
;; or `light'.  A mounted reader repaints when a session's `:theme' value
;; changes, which is what the reader's T key does.
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
(require 'etaf-weread-model)
(require 'etaf-weread-views)
(require 'etaf-weread-app)

(provide 'etaf-weread)
;;; etaf-weread.el ends here
