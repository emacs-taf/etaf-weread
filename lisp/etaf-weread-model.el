;;; etaf-weread-model.el --- Reader state and backend actions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The model owns everything a reader session remembers: the selected section,
;; the visible book rows, the keyboard selection, the book detail shown in the
;; side pane and its highlights, and the account and reading statistics.  Every
;; mutable value is an ETAF reactive source, so a View that reads it repaints
;; when a backend reply arrives; every backend request is asynchronous and its
;; reply is dropped when it belongs to a superseded load.
;;
;; The model is independent of any buffer: `etaf-weread-create' plus the public
;; actions drive a complete session headlessly, which is how the acceptance
;; scenarios exercise it with a fake client.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-weread-service)
(require 'etaf-weread-index)
(require 'etaf-weread-theme)
(require 'etaf-weread-library)

(defconst etaf-weread-sections
  '((书架
     (:shelf "全部书架" list)
     (:reading "在读" clock)
     (:finished "读完" check))
    (笔记
     (:notebook "笔记本" lyrics)
     (:index "笔记检索" search))
    (本地
     (:local "本地书" queue))
    (发现
     (:search "搜索书城" star)
     (:stats "阅读统计" chart)))
  "Sidebar groups shown by the reader.
Each group is (GROUP-NAME (SECTION LABEL ICON) ...), where ICON names an
`etaf-ui-icon' in the shared SVG set; SECTION keys are accepted by
`etaf-weread-locate'.")

(defconst etaf-weread--section-subtitles
  '((:local . "本地文件里的书")
    (:shelf . "书架里的全部书")
    (:reading . "最近在读的书")
    (:finished . "已经读完的书")
    (:notebook . "有划线和想法的书")
    (:index . "本地索引的全部划线与想法")
    (:search . "搜索微信读书书城")
    (:stats . "读完与在读 · 累计阅读时长"))
  "One-line explanation shown under each section title.")

(defcustom etaf-weread-page-size 16
  "Book rows shown at once.
`etaf-weread-open' replaces this with the number that fits the window, so the
reader fills the frame it is given; the default only applies to a headless
model created by `etaf-weread-create'."
  :type 'integer
  :group 'etaf-weread)

(defconst etaf-weread--sidebar-columns 22
  "Frame columns the section sidebar occupies.")

(defconst etaf-weread--rail-columns 7
  "Frame columns the glyph-only section rail of a medium layout occupies.")

(defconst etaf-weread--pane-columns 46
  "Frame columns the side pane occupies, including its border and padding.")

(defconst etaf-weread--pane-content-columns 36
  "Usable text columns inside the side pane.
The pane's frame width minus its border and padding; the reader wraps a local
chapter to this width so no line is clipped.")

(defconst etaf-weread--list-min-columns 70
  "Frame columns the book list needs to render one full row.
The full row spends 50 columns on everything but the title (index, author,
meter, time, badge and the gaps), so a narrower list leaves the title too few
columns to be recognizable and the row reads as broken.")

(defcustom etaf-weread-wide-columns (+ etaf-weread--sidebar-columns
                                      etaf-weread--pane-columns
                                      etaf-weread--list-min-columns)
  "Frame width, in columns, that fits all three reader columns.
At or above this width the reader shows the section sidebar, the book list and
the detail pane at the same time (`wide' layout).  Between
`etaf-weread-medium-columns' and this width it keeps a narrow glyph rail and
shows one pane at a time; below it the sections move into a chip strip.
Derived from the sidebar, the pane and the list's minimum, so the frame can
never show three columns the book list cannot render in."
  :type 'integer
  :group 'etaf-weread)

(defcustom etaf-weread-medium-columns 68
  "Frame width, in columns, that still fits a glyph-only section rail."
  :type 'integer
  :group 'etaf-weread)

(defcustom etaf-weread-list-limit 200
  "Rows requested from the backend for one list load.
A larger shelf is still navigated through the loaded rows; the footer reports
the backend total when the reply is partial."
  :type 'integer
  :group 'etaf-weread)

(defcustom etaf-weread-search-count 25
  "Book results requested for one store search."
  :type 'integer
  :group 'etaf-weread)

(defcustom etaf-weread-detail-follow-delay 0.3
  "Seconds of quiet before the detail pane follows the selection.
Moving through the list faster than this never requests a book that was only
passed over, so browsing stays cheap on the network."
  :type 'number
  :group 'etaf-weread)

(defcustom etaf-weread-library-refresh-interval 120
  "Seconds after which a cached list is refreshed in the background.
A cached list is shown at once when a section is opened, then compared with a
fresh reply; the cache is a display shortcut, never the source of truth.  A
shorter interval keeps the sidebar current at the cost of more requests."
  :type 'number
  :group 'etaf-weread)

(defcustom etaf-weread-prefetch-lists t
  "Whether a mounted reader refreshes sidebar lists while it is idle.
One list at a time is warmed or refreshed in the background, so switching
sections shows current data without waiting for the network."
  :type 'boolean
  :group 'etaf-weread)

(defcustom etaf-weread-prefetch-interval 15
  "Seconds between two background list refreshes while the reader is idle."
  :type 'number
  :group 'etaf-weread)

(defconst etaf-weread--reading-min-columns 24
  "Narrowest reading column the reader allows.")

(defconst etaf-weread--reading-max-columns 96
  "Widest reading column the reader allows.")

(defconst etaf-weread--reader-gutter 3
  "Columns between two reading columns shown side by side.")

(defconst etaf-weread--reader-max-columns 4
  "Most reading columns a pane shows side by side, however wide it is.")

(defcustom etaf-weread-reading-measure 44
  "Width in columns of one local reading column.
A local chapter is wrapped to this many columns and the column is centered in
the reading pane, which is what keeps a wide frame readable.  `[' and `]'
adjust it while reading and the choice is stored in `etaf-weread-settings-file'."
  :type 'integer
  :group 'etaf-weread)

(defcustom etaf-weread-reading-spread 'auto
  "Reading columns shown side by side, or `auto' for as many as fit.
`auto' (the default) shows as many columns of `etaf-weread-reading-measure'
as the pane can hold, up to `etaf-weread--reader-max-columns'; a number pins
the count, and a frame too narrow for it falls back to what fits.  The
reader's `m' key cycles the choice and it is stored in
`etaf-weread-settings-file'."
  :type '(choice (const :tag "As many as fit" auto) (integer 1 4))
  :group 'etaf-weread)

(defconst etaf-weread--reader-fonts '(small medium large)
  "Reading font presets, narrowest first.")

(defconst etaf-weread--reader-font-scales
  '((small . 0.85) (medium . 1.0) (large . 1.3))
  "Size of each reading font preset relative to the frame's default font.")

(defcustom etaf-weread-reading-font 'medium
  "Font size preset of a local book's text: `small', `medium' or `large'.
`medium' keeps the frame's own font; the other presets scale the reading text
and the row budget together, so a larger font fits fewer rows of the same
chapter and never overflows the window.  The reader's `F' key cycles the
presets and the choice is stored in `etaf-weread-settings-file'."
  :type '(choice (const :tag "Small" small)
                 (const :tag "Frame default" medium)
                 (const :tag "Large" large))
  :group 'etaf-weread)

(defcustom etaf-weread-settings-file
  (locate-user-emacs-file "etaf-weread/settings.eld")
  "File that stores the reading preferences between sessions.
It keeps the chosen appearance, the reading width, the column count and where
reading stopped in every local book, so a new session starts where the last
one left off.  Bind it before creating a session to keep several profiles
apart."
  :type 'file
  :group 'etaf-weread)

(defcustom etaf-weread-remember-positions t
  "Whether the reader returns to where each local book was left.
The chapter and the position inside it are stored in
`etaf-weread-settings-file', and opening the book again continues from there.
The position inside a chapter is a fraction, so it survives a different frame
size or reading width."
  :type 'boolean
  :group 'etaf-weread)

(defcustom etaf-weread-position-save-delay 1.5
  "Seconds of quiet before a scrolled position is stored.
Scrolling writes often, and the preference file is small but not free, so a
scrolled position settles before it is written."
  :type 'number
  :group 'etaf-weread)

(defcustom etaf-weread-auto-scroll-interval 6
  "Seconds auto-scroll waits before advancing one reading line.
A comfortable line pace is a handful of seconds; the reader's `a' key turns
auto-scroll on and off and the pace applies while it runs."
  :type 'number
  :group 'etaf-weread)

(declare-function youdao-dictionary-search "youdao-dictionary" (query))

(defcustom etaf-weread-dictionary-buffer-name "*ETAF 词典*"
  "Buffer the lookup backends display a definition in."
  :type 'string
  :group 'etaf-weread)

(defun etaf-weread--youdao-configured-p ()
  "Return non-nil when the installed `youdao-dictionary' has API credentials.
The package needs a Youdao app key and secret; without them its request
signals before it reaches the network."
  (and (require 'youdao-dictionary nil t)
       (boundp 'youdao-dictionary-app-key)
       (stringp youdao-dictionary-app-key)
       (not (string-empty-p youdao-dictionary-app-key))
       (boundp 'youdao-dictionary-secret-key)
       (stringp youdao-dictionary-secret-key)
       (not (string-empty-p youdao-dictionary-secret-key))))

(defun etaf-weread-youdao-lookup (query)
  "Show QUERY's entry from the `youdao-dictionary' package.
The package's API key and secret must be configured; otherwise
`etaf-weread-error' signals and the reader keeps running."
  (unless (require 'youdao-dictionary nil t)
    (signal 'etaf-weread-error
            '("未安装 youdao-dictionary（M-x package-install RET youdao-dictionary）")))
  (youdao-dictionary-search query))

(defconst etaf-weread--macos-lookup-script
  (concat "import Foundation\n"
          "import CoreServices\n"
          "let word = ProcessInfo.processInfo.environment[\"WEREAD_QUERY\"] ?? \"\"\n"
          "if let definition = DCSCopyTextDefinition(nil, word as CFString,\n"
          "        CFRangeMake(0, word.utf16.count)) {\n"
          "  print(definition.takeRetainedValue() as String)\n"
          "}\n")
  "Swift program reading one word's macOS dictionary definition.
The word arrives in the WEREAD_QUERY environment variable so no shell
quoting is involved, and the definition goes to standard output.")

(defun etaf-weread-macos-lookup (query)
  "Show QUERY's definition from the macOS system dictionaries.
`swift' reads the definition through the DictionaryServices framework, so the
lookup uses whatever dictionaries the system has and needs no account.  A word
the dictionaries do not know signals `etaf-weread-error'; macOS only."
  (unless (eq system-type 'darwin)
    (signal 'etaf-weread-error '("macOS 系统词典仅在 macOS 上可用")))
  (let ((process-environment (cons (concat "WEREAD_QUERY=" query)
                                   process-environment))
        definition)
    (with-temp-buffer
      (let ((status (call-process "swift" nil t nil
                                  "-e" etaf-weread--macos-lookup-script)))
        (unless (zerop status)
          (signal 'etaf-weread-error
                  (list (format "系统词典查询失败（swift 退出 %s）" status))))
        (setq definition (string-trim (buffer-string)))))
    (when (string-empty-p definition)
      (signal 'etaf-weread-error (list (format "词典里没有找到「%s」" query))))
    (etaf-weread--show-definition query definition)))

(defun etaf-weread--show-definition (query definition)
  "Show QUERY and DEFINITION in `etaf-weread-dictionary-buffer-name'.
The buffer opens below the reader without taking its focus, so looking a word
up does not interrupt the reading."
  (let ((buffer (get-buffer-create etaf-weread-dictionary-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize query 'face 'bold) "\n\n" definition "\n")
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buffer
                    '((display-buffer-reuse-window display-buffer-below-selected)
                      (window-height . 0.35)))
    buffer))

(defun etaf-weread-default-lookup (query)
  "Show QUERY's definition with the best available backend.
A `youdao-dictionary' with its API credentials configured is used first;
elsewhere the macOS system dictionary serves the lookup.  A machine with
neither signals `etaf-weread-error' and suggests setting
`etaf-weread-dictionary-function'."
  (cond
   ((etaf-weread--youdao-configured-p) (etaf-weread-youdao-lookup query))
   ((eq system-type 'darwin) (etaf-weread-macos-lookup query))
   (t (signal 'etaf-weread-error
              '("没有可用的词典：配置 youdao-dictionary 的 API key/secret，或设置 etaf-weread-dictionary-function")))))

(defcustom etaf-weread-dictionary-function #'etaf-weread-default-lookup
  "Function of one string that shows a dictionary entry for it.
The reader's `y' key passes the selected text or the line at the top of the
visible chapter.  The default uses a configured `youdao-dictionary', falls
back to the macOS system dictionary, and can be replaced with any backend,
for example one that displays a translation of a whole sentence."
  :type 'function
  :group 'etaf-weread)

(defconst etaf-weread--position-limit 50
  "Local books whose reading position is kept.")

(defconst etaf-weread--bookmark-limit 200
  "Bookmarks kept across all local books.")

(defconst etaf-weread--reading-limit 50
  "Local books whose reading time is kept.")

(defconst etaf-weread--reading-chapter-limit 300
  "Chapter indices one book's reading record keeps, newest first.")

(defcustom etaf-weread-local-note-matching t
  "Whether a local book shows the account's highlights of the same title.
Opening a local book looks for it in the notebook, fetches the highlights of
the best match and marks the lines they share with the local text; `N' jumps
to the next match.  Turn it off to keep local reading entirely offline."
  :type 'boolean
  :group 'etaf-weread)

(defcustom etaf-weread-track-reading-time t
  "Whether the reader records how long and how far a local book was read.
The record holds the total seconds and the chapter indices opened so far; it
lives in `etaf-weread-settings-file' and is what
`etaf-weread-reading-stats' reports."
  :type 'boolean
  :group 'etaf-weread)

(defconst etaf-weread--search-match-limit 200
  "Most matches an in-book search returns.")

;;; ---------------------------------------------------------------------------
;;; Reading preferences
;;; ---------------------------------------------------------------------------

(defun etaf-weread--settings-read ()
  "Return the stored reading preferences as a property plist.
A missing file means the defaults, and a corrupt one is ignored rather than
breaking the session."
  (condition-case nil
      (when (file-readable-p etaf-weread-settings-file)
        (with-temp-buffer
          (insert-file-contents etaf-weread-settings-file)
          (let ((stored (read (current-buffer))))
            (and (listp stored) stored))))
    (error nil)))

(defun etaf-weread--settings-write (app)
  "Store APP's reading preferences for the next session.
The session remembers the file it was created with, so binding
`etaf-weread-settings-file' around `etaf-weread-create' keeps its writes in
that file too.  A failed write is reported in the status line instead of
signalling: losing a preference must not interrupt the reading."
  (condition-case error
      (let ((file (or (plist-get app :settings-file) etaf-weread-settings-file)))
        (make-directory (file-name-directory (expand-file-name file)) t)
        (with-temp-file file
          (prin1 (list :theme etaf-weread-theme-mode
                       :reader-measure (etaf-weread--read app :reader-measure)
                       :reader-spread (etaf-weread--read app :reader-spread)
                       :reader-font (etaf-weread--read app :reader-font)
                       :positions (plist-get app :positions)
                       :bookmarks (plist-get app :bookmarks)
                       :reading (plist-get app :reading))
                 (current-buffer))))
    (error
     (etaf-weread--write app :message
                         (format "无法保存阅读设置：%s" (error-message-string error))))))

;;; ---------------------------------------------------------------------------
;;; Construction and reactive access
;;; ---------------------------------------------------------------------------

(cl-defun etaf-weread-create (&key client)
  "Create a reader session that talks to CLIENT.
CLIENT defaults to `etaf-weread-client-factory' when that is bound, and
otherwise to `etaf-weread-make-client'.  The session owns no buffer and no
timer until it is mounted by `etaf-weread-app' or started by
`etaf-weread-refresh'; it is also a complete headless reader for tests and
other Lisp callers."
  (let* ((client (or client
                     (if etaf-weread-client-factory
                         (funcall etaf-weread-client-factory)
                       (etaf-weread-make-client))))
         (settings (etaf-weread--settings-read))
         (measure (or (plist-get settings :reader-measure)
                      etaf-weread-reading-measure))
         (spread (let ((stored (plist-get settings :reader-spread)))
                   (if (or (eq stored 'auto)
                           (and (integerp stored) (<= 1 stored 4)))
                       stored
                     etaf-weread-reading-spread)))
         (font (let ((stored (plist-get settings :reader-font)))
                 (if (memq stored etaf-weread--reader-fonts)
                     stored
                   etaf-weread-reading-font))))
    (when (memq (plist-get settings :theme) '(dark light sepia))
      (setq etaf-weread-theme-mode (plist-get settings :theme)))
    (list :client client
          :buffer nil
          :settings-file etaf-weread-settings-file
          :positions (let ((stored (plist-get settings :positions)))
                       (and (listp stored) stored))
          :bookmarks (let ((stored (plist-get settings :bookmarks)))
                       (and (listp stored) stored))
          :reading (let ((stored (plist-get settings :reading)))
                     (and (listp stored) stored))
          :reading-path nil
          :reading-since nil
          :reading-visited nil
          :local-note-id nil
          :position-timer nil
          :auto-scroll-timer nil
          :disposed nil
          :started-at nil
          :follow-timer nil
          :generation 0
          :detail-generation 0
          :notes-generation 0
          :list-key nil
          :list-cache (etaf-list-cache-create :grace 3)
          :detail-cache (make-hash-table :test 'equal)
          :notes-cache (make-hash-table :test 'equal)
          :section (etaf-ref :shelf :name 'etaf-weread-section)
          :filter (etaf-ref "all" :name 'etaf-weread-filter)
          :mode (etaf-ref 'browse :name 'etaf-weread-mode)
          :query (etaf-ref "" :name 'etaf-weread-query)
          :title (etaf-ref "全部书架" :name 'etaf-weread-title)
          :subtitle (etaf-ref "书架里的全部书" :name 'etaf-weread-subtitle)
          :rows (etaf-ref nil :name 'etaf-weread-rows)
          :list-total (etaf-ref 0 :name 'etaf-weread-list-total)
          :selection (etaf-ref 0 :name 'etaf-weread-selection)
          :window-start (etaf-ref 0 :name 'etaf-weread-window-start)
          :window-rows (etaf-ref 0 :name 'etaf-weread-window-rows)
          :page-size (etaf-ref etaf-weread-page-size :name 'etaf-weread-page-size)
          :pane (etaf-ref 'list :name 'etaf-weread-pane)
          :pane-scroll (etaf-ref 0 :name 'etaf-weread-pane-scroll)
          :pane-rows (etaf-ref 10 :name 'etaf-weread-pane-rows)
          :reader-rows (etaf-ref 12 :name 'etaf-weread-reader-rows)
          :pane-total (etaf-ref 0 :name 'etaf-weread-pane-total)
          :local (etaf-ref nil :name 'etaf-weread-local)
          :local-notes (etaf-ref nil :name 'etaf-weread-local-notes)
          :local-bindings (etaf-ref nil :name 'etaf-weread-local-bindings)
          :reader-lines (etaf-ref nil :name 'etaf-weread-reader-lines)
          :reader-title (etaf-ref "" :name 'etaf-weread-reader-title)
          :reader-measure (etaf-ref measure :name 'etaf-weread-reader-measure)
          :reader-font (etaf-ref font :name 'etaf-weread-reader-font)
          :reader-font-size (etaf-ref nil :name 'etaf-weread-reader-font-size)
          :reader-line-height (etaf-ref (frame-char-height) :name 'etaf-weread-reader-line-height)
          :reader-canvas (etaf-ref (frame-height) :name 'etaf-weread-reader-canvas)
          :reader-columns (etaf-ref measure :name 'etaf-weread-reader-columns)
          :reader-wrapped (etaf-ref 0 :name 'etaf-weread-reader-wrapped)
          :reader-spread (etaf-ref spread :name 'etaf-weread-reader-spread)
          :reader-shown (etaf-ref 1 :name 'etaf-weread-reader-shown)
          :reader-capacity (etaf-ref 0 :name 'etaf-weread-reader-capacity)
          :reader-progress (etaf-ref 0 :name 'etaf-weread-reader-progress)
          :auto-scroll (etaf-ref nil :name 'etaf-weread-auto-scroll)
          :zen (etaf-ref nil :name 'etaf-weread-zen)
          :detail (etaf-ref nil :name 'etaf-weread-detail)
          :notes (etaf-ref nil :name 'etaf-weread-notes)
          :stats (etaf-ref nil :name 'etaf-weread-stats)
          :index-query (etaf-ref "" :name 'etaf-weread-index-query)
          :index-syncing (etaf-ref nil :name 'etaf-weread-index-syncing)
          :index-controller nil
          :index-generation 0
          :index-pending nil
          :account (etaf-ref nil :name 'etaf-weread-account)
          :summary (etaf-ref "" :name 'etaf-weread-summary)
          :theme (etaf-ref (etaf-weread-theme-defaults) :name 'etaf-weread-theme)
          :layout (etaf-ref 'wide :name 'etaf-weread-layout)
          :loading (etaf-ref nil :name 'etaf-weread-loading)
          :error (etaf-ref nil :name 'etaf-weread-error)
          :message (etaf-ref nil :name 'etaf-weread-message))))

(defun etaf-weread--ref (app key)
  "Return APP's reactive source named KEY."
  (plist-get app key))

(defun etaf-weread--read (app key)
  "Return APP's current value for KEY, tracked while rendering."
  (etaf-value (etaf-weread--ref app key)))

(defun etaf-weread--write (app key value)
  "Publish VALUE as APP's new value for KEY; return VALUE.
A write that would not change the reading is skipped: the reader re-renders on
every write, and a reply that repeats the previous reading would otherwise
repaint the whole view for nothing."
  (let ((ref (etaf-weread--ref app key)))
    (unless (equal (etaf-value ref) value)
      (etaf-set-value ref value))
    value))

(defun etaf-weread--client (app)
  "Return APP's backend client."
  (plist-get app :client))

(cl-defun etaf-weread--call (app request &key on-ok on-error)
  "Send REQUEST for APP, routing a failure into the visible status line.
ON-OK receives the reply data; ON-ERROR the failure message, its hint and the
skill's error code.  A client that
signals while turning the request into a command is reported like any other
backend failure, so nothing reaches the caller of a reader action."
  (let ((delivered nil)
        (fail (lambda (message hint code)
                (etaf-weread--write app :error message)
                (etaf-weread--write app :message
                                    (if (and hint (not (string-empty-p hint)))
                                        (format "%s（%s）" message hint)
                                      message))
                (when on-error (funcall on-error message hint code)))))
    (condition-case error
        (etaf-weread-client-call
         (etaf-weread--client app) request
         (lambda (result)
           (setq delivered t)
           (if (eq (car result) :ok)
               (progn
                 (etaf-weread--write app :error nil)
                 (when on-ok (funcall on-ok (cadr result))))
             (funcall fail (or (cadr result) "请求失败")
                      (plist-get (cddr result) :hint)
                      (plist-get (cddr result) :code)))))
      (error (if delivered
                 (signal (car error) (cdr error))
               (funcall fail (error-message-string error) nil nil))))))

(defun etaf-weread--note (app text)
  "Show TEXT as the reader's status line message."
  (etaf-weread--write app :message text))

;;; ---------------------------------------------------------------------------
;;; Formatting helpers
;;; ---------------------------------------------------------------------------

(defun etaf-weread--payload (data)
  "Return the business payload of backend reply DATA.
A skill reply wraps its fields in a `data' object beside `ok', `conclusion' and
`as_of'; a scripted client may pass the fields directly, which this helper
accepts as well."
  (or (plist-get data :data) data))

(defun etaf-weread-format-duration (seconds)
  "Return SECONDS as a compact reading time such as \"1小时13分\" or \"10分\".
Zero or missing time returns an empty string so a row can omit the column."
  (let ((total (max 0 (round (or (and (numberp seconds) seconds) 0)))))
    (if (zerop total)
        ""
      (let ((hours (/ total 3600))
            (minutes (/ (% total 3600) 60)))
        (cond ((and (> hours 0) (> minutes 0)) (format "%d小时%d分" hours minutes))
              ((> hours 0) (format "%d小时" hours))
              (t (format "%d分" minutes)))))))

(defun etaf-weread-progress-bar (percent &optional width)
  "Return a text progress bar of WIDTH cells for PERCENT (0 to 100).
WIDTH defaults to 8.  The filled part uses U+2588 and the remainder U+2591, so
the bar reads as one glyph string in any monospace font."
  (let* ((width (max 1 (or width 8)))
         (ratio (max 0.0 (min 1.0 (/ (float (or (and (numberp percent) percent) 0))
                                     100.0))))
         (filled (round (* ratio width))))
    (concat (make-string filled ?\u2588)
            (make-string (- width filled) ?\u2591))))

(defun etaf-weread--parse-number (value)
  "Return VALUE as a number, or nil when it is empty or not numeric."
  (cond ((numberp value) value)
        ((eq value :false) nil)
        ((not (stringp value)) nil)
        (t (let ((text (string-trim value)))
             (and (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\'" text)
                  (string-to-number text))))))

(defun etaf-weread--string (value)
  "Return VALUE as a trimmed string, or an empty string."
  (let ((text (cond ((stringp value) value)
                    ((numberp value) (number-to-string value))
                    ((eq value :false) "")
                    (t ""))))
    (string-trim text)))

(defun etaf-weread--list (value)
  "Return VALUE as a list, or nil when it is not one."
  (if (listp value) value nil))

(defun etaf-weread--required-number (value)
  "Return VALUE as a number, defaulting to 0."
  (or (etaf-weread--parse-number value) 0))

(defun etaf-weread--truthy-p (value)
  "Return non-nil when VALUE means true in a backend reply.
The skill writes booleans as JSON true/false, but some legacy fields are 1/0
numbers or \"true\" strings."
  (cond ((eq value t) t)
        ((numberp value) (/= value 0))
        ((stringp value) (member (downcase (string-trim value))
                                 '("true" "1" "yes")))
        (t nil)))

(defun etaf-weread--rating-text (value)
  "Return rating VALUE as \"9.3\", or an empty string.
The backend reports ratings as tenths (93 means 9.3)."
  (let ((rating (etaf-weread--parse-number value)))
    (if (and rating (> rating 0))
        (if (> rating 10)
            (format "%.1f" (/ rating 10.0))
          (format "%.1f" (float rating)))
      "")))

(defun etaf-weread--progress-text (percent)
  "Return PERCENT as \"36%\", or an empty string when it is missing."
  (let ((percent (etaf-weread--parse-number percent)))
    (if (and percent (> percent 0))
        (format "%d%%" (round percent))
      "")))

;;; ---------------------------------------------------------------------------
;;; Section labels and list loading
;;; ---------------------------------------------------------------------------

(defun etaf-weread--section-label (section)
  "Return the sidebar label of SECTION, or nil."
  (seq-some (lambda (group)
              (when-let* ((entry (assq section (cdr group))))
                (nth 1 entry)))
            etaf-weread-sections))

(defun etaf-weread--section-glyph (section)
  "Return the sidebar glyph of SECTION, or an empty string."
  (or (seq-some (lambda (group)
                  (when-let* ((entry (assq section (cdr group))))
                    (nth 2 entry)))
                etaf-weread-sections)
      ""))

(defun etaf-weread-set-filter (app filter)
  "Show the shelf FILTER in APP and load its books.
FILTER is `all' (or \"all\"), `reading' (or \"reading\") or `finished' (or
\"finished\"); the matching section `:shelf', `:reading' or `:finished' is
shown.  Anything else signals `etaf-weread-error'."
  (let* ((filter (string-remove-prefix ":" (downcase (format "%s" filter))))
         (section (pcase filter
                    ((or "all" "shelf") :shelf)
                    ((or "reading" "in-progress") :reading)
                    ((or "finished" "done") :finished)
                    (_ (signal 'etaf-weread-error
                               (list (format "Unknown shelf filter: %S" filter)))))))
    (etaf-weread-locate app section)))

(defun etaf-weread--shelf-filter (section)
  "Return the backend filter string of shelf SECTION."
  (pcase section
    (:reading "reading")
    (:finished "finished")
    (_ "all")))

(defun etaf-weread-locate (app section)
  "Show SECTION of APP and load its rows.
SECTION is one of the keys in `etaf-weread-sections': `:shelf', `:reading',
`:finished', `:notebook', `:search' or `:stats'.  A cached list is shown at
once and refreshed in the background; the first visit waits for the backend,
and a reply from an earlier section is discarded.  Unknown SECTION signals
`etaf-weread-error'."
  (unless (etaf-weread--section-label section)
    (signal 'etaf-weread-error (list (format "Unknown section: %S" section))))
  (let* ((key (etaf-weread--list-key app section))
         (same-p (equal key (plist-get app :list-key))))
    (etaf-batch
      (etaf-weread--write app :section section)
      (etaf-weread--write app :title (or (etaf-weread--section-label section) "书架"))
      (etaf-weread--write app :subtitle
                          (or (cdr (assq section etaf-weread--section-subtitles)) ""))
      (etaf-weread--write app :mode
                          (pcase section
                            (:search 'search)
                            (:index 'index)
                            (:stats 'stats)
                            (_ 'browse)))
      (etaf-weread--write app :filter (etaf-weread--shelf-filter section))
      (etaf-weread--write app :pane-scroll 0)
      (etaf-weread--show-list-pane app)
      (setf (plist-get app :list-key) key)
      (etaf-weread--show-cached-list app key same-p))
    (if (eq section :local)
        (etaf-weread--show-local-books app)
      (if (eq section :index)
          (etaf-weread--index-reload app)
      (cond ((eq section :search)
             (when (not (string-empty-p (etaf-weread--read app :query)))
               (etaf-weread--load-list
                app key (etaf-weread--list-request app section) same-p
                (and (etaf-weread--list-entry app key) t))))
              (t (etaf-weread--load-list
                  app key (etaf-weread--list-request app section) same-p
                  (and (etaf-weread--list-entry app key) t))))))))

(defun etaf-weread--show-local-books (app)
  "Fill APP's list with the books under `etaf-weread-library-directory'.
A local book needs no backend, so the rows appear synchronously."
  (let* ((directory etaf-weread-library-directory)
         (books (etaf-weread-library-books directory))
         (rows (mapcar (lambda (book)
                         (list :id (plist-get book :path)
                               :title (plist-get book :title)
                               :author (or (plist-get book :author) "")
                               :badge (upcase (or (plist-get book :format) ""))
                               :local t
                               :progress 0))
                       books)))
    (etaf-batch
      (etaf-weread--write app :rows rows)
      (etaf-weread--write app :loading nil)
      (etaf-weread--write app :list-total (length rows))
      (etaf-weread--write app :selection 0)
      (etaf-weread--write app :window-start 0)
      (etaf-weread--write app :summary (format "本地书 %d 本" (length rows))))
    (etaf-weread--note
     app (if (file-directory-p directory)
             (format "本地书库：%s（%d 本）" directory (length rows))
           (format "本地书库目录不存在：%s" directory)))
    (etaf-weread--local-bindings-load app)))

(defconst etaf-weread--paragraph-indent "    "
  "Indent a Chinese book starts a paragraph with, in columns.
Plain spaces: the ideographic space (U+3000) renders as an underlined escape
glyph whenever the reader's font has no glyph for it, which looks like a
stray rule above the first line of every paragraph.")

(defun etaf-weread--wrap-text (text columns &optional indent)
  "Return TEXT as lines no wider than COLUMNS display columns.
Explicit line breaks are kept, so a poem stays as the file wrote it; a long
line is folded between characters, counting CJK as two columns.  When INDENT
is non-nil it starts every paragraph that follows a blank line, the way a
Chinese book indents paragraphs; the first line stays flush because it carries
the chapter heading."
  (let ((lines nil)
        (first t)
        (paragraph-start nil))
    (dolist (source (split-string (replace-regexp-in-string "\t" "    " text) "\n"))
      (let* ((blank (string-empty-p (string-trim source)))
             (line (if (and indent paragraph-start (not blank) (not first))
                       (concat indent source)
                     source))
             (current "") (width 0))
        (dolist (char (string-to-list line))
          (let ((char-width (char-width char)))
            (when (and (> (+ width char-width) columns)
                       (not (string-empty-p current)))
              (push (string-trim-right current) lines)
              (setq current "" width 0))
            (setq current (concat current (char-to-string char))
                  width (+ width char-width))))
        (push (string-trim-right current) lines)
        (setq first nil
              paragraph-start blank)))
    (nreverse lines)))

(defun etaf-weread--publish-local-chapter (app)
  "Publish APP's current local chapter into the reading pane.
A line that overlaps one of the account's highlights of the same book (see
`etaf-weread-match-local-notes') is marked with `:note', which is what the
reading view paints as a highlight bar."
  (let* ((local (etaf-weread--read app :local))
         (chapters (plist-get local :chapters))
         (index (or (plist-get local :index) 0))
         (chapter (nth index chapters))
         (text (or (plist-get chapter :text) ""))
         (lines (cl-loop for line in (etaf-weread--wrap-text
                                      text (etaf-weread--reading-columns app)
                                      etaf-weread--paragraph-indent)
                         for position from 1
                         collect (list :key position :text line)))
         (notes (etaf-weread--chapter-notes app index)))
    (dolist (position (etaf-weread--note-line-indices lines notes))
      (plist-put (nth position lines) :note t))
    (etaf-batch
      (etaf-weread--write app :reader-lines lines)
      (etaf-weread--write app :reader-title
                          (format "%s · 第 %d/%d 章 · %s"
                                  (or (plist-get local :title) "")
                                  (1+ index) (length chapters)
                                  (or (plist-get chapter :title) "")))
      (etaf-weread--write app :reader-wrapped (etaf-weread--reading-columns app))
      (etaf-weread--write app :pane 'reader)
      (etaf-weread--sync-pane-total app))
    (etaf-weread--update-reader-progress app)
    (etaf-weread--note app (or (plist-get local :title) "本地书"))))

(defun etaf-weread-open-local-book (app path)
  "Open the local book at PATH in APP's reading pane.
Return the number of chapters the book has.  An unreadable or unsupported file
signals `etaf-weread-error'."
  (let* ((content (etaf-weread-library-content path))
         (chapters (plist-get content :chapters)))
    ;; The reading budget and the column count come from the window, so fit the
    ;; layout before a chapter is wrapped and a stored position is applied.
    (etaf-weread--sync-layout app)
    (etaf-batch
      (etaf-weread--write app :local
                          (list :path path
                                :title (plist-get content :title)
                                :format (plist-get content :format)
                                :chapters chapters
                                :index 0))
      (etaf-weread--write app :pane-scroll 0))
    (etaf-weread--publish-local-chapter app)
    ;; Publishing showed the reading pane, so the canvas may have to shrink
    ;; before the stored position is resolved against the new row budget.
    (etaf-weread--sync-layout app)
    (etaf-weread--restore-position app)
    (etaf-weread--reading-begin app)
    (etaf-weread--reading-note app)
    (when etaf-weread-local-note-matching
      (etaf-weread--local-bindings-load
       app (lambda () (etaf-weread-match-local-notes app))))
    (length chapters)))

(defun etaf-weread--position-record (app)
  "Return APP's reading position as a plist, or nil when nothing is open.
The position inside the chapter is a fraction of its scrollable rows, so it
survives a different frame size or reading width."
  (let* ((local (etaf-weread--read app :local))
         (path (plist-get local :path))
         (chapters (length (plist-get local :chapters))))
    (when (and path (> chapters 0))
      (let* ((rows (max 1 (etaf-weread--pane-page-rows app)))
             (total (max 1 (etaf-weread--read app :pane-total)))
             (span (max 1 (- total rows)))
             (scroll (etaf-weread--read app :pane-scroll)))
        (list :path path
              :chapter (or (plist-get local :index) 0)
              :fraction (min 1.0 (max 0.0 (/ (float scroll) span)))
              :at (float-time))))))

(defun etaf-weread--remember-position (app)
  "Store APP's current reading position, newest first, for the next session.
A book keeps one position: reading it again replaces the previous one, and
only the most recent `etaf-weread--position-limit' books are kept."
  (when etaf-weread-remember-positions
    (when-let* ((record (etaf-weread--position-record app)))
      (let* ((path (plist-get record :path))
             (kept (seq-remove (lambda (entry)
                                 (equal (plist-get entry :path) path))
                               (plist-get app :positions))))
        (setf (plist-get app :positions)
              (seq-take (cons record kept) etaf-weread--position-limit))
        (etaf-weread--settings-write app)
        record))))

(defun etaf-weread--schedule-position-save (app)
  "Store APP's reading position and time once the scrolling settles.
Both readings are written by the same quiet timer because both are only worth
writing when the reader stopped moving; the timer runs when either feature
wants it, so turning positions off still counts reading time."
  (when (and (or etaf-weread-remember-positions
                 etaf-weread-track-reading-time)
             (plist-get (etaf-weread--read app :local) :chapters))
    (when-let* ((timer (plist-get app :position-timer)))
      (cancel-timer timer))
    (setf (plist-get app :position-timer)
          (run-at-time etaf-weread-position-save-delay nil
                       (lambda ()
                         (setf (plist-get app :position-timer) nil)
                         (unless (plist-get app :disposed)
                           (etaf-weread--reading-accumulate app)
                           (etaf-weread--remember-position app)))))))

(defun etaf-weread--restore-position (app)
  "Continue APP's local book where the last session left it.
The chapter is restored exactly and the position inside it from the stored
fraction, so a different frame size or reading width still lands in the same
place.  A book without a stored position keeps its first chapter."
  (when etaf-weread-remember-positions
    (let* ((local (etaf-weread--read app :local))
           (entry (seq-find (lambda (item)
                              (equal (plist-get item :path) (plist-get local :path)))
                            (plist-get app :positions))))
      (when entry
        (etaf-weread-read-chapter app (1+ (or (plist-get entry :chapter) 0)))
        (let* ((rows (max 1 (etaf-weread--pane-page-rows app)))
               (total (max 1 (etaf-weread--read app :pane-total)))
               (span (max 0 (- total rows)))
               (scroll (round (* (or (plist-get entry :fraction) 0.0) span))))
          (etaf-batch
            (etaf-weread--write app :pane-scroll scroll))
          (etaf-weread--update-reader-progress app)
          ;; `etaf-weread-read-chapter' recorded the top of the chapter on its
          ;; way here; correct the record to the restored position.
          (etaf-weread--remember-position app))))))

(defun etaf-weread--reader-line-text (app index)
  "Return the text of APP's visible line INDEX, or nil."
  (let ((lines (etaf-weread--read app :reader-lines)))
    (when (and lines (>= index 0) (< index (length lines)))
      (plist-get (nth index lines) :text))))

(defun etaf-weread--bookmarks-for (app path)
  "Return APP's bookmarks for PATH, newest first."
  (seq-filter (lambda (entry) (equal (plist-get entry :path) path))
              (plist-get app :bookmarks)))

(defun etaf-weread-toggle-bookmark (app)
  "Add or remove a bookmark at APP's reading place.
A bookmark within a fiftieth of the current place counts as the same one, so
the same key removes what it added.  Return the current book's bookmarks,
newest first; the list is stored in `etaf-weread-settings-file'."
  (let* ((local (etaf-weread--read app :local))
         (path (plist-get local :path))
         (record (etaf-weread--position-record app)))
    (unless (and path record)
      (signal 'etaf-weread-error '("先打开一本本地书")))
    (let* ((same (lambda (entry)
                   (and (equal (plist-get entry :chapter) (plist-get record :chapter))
                        (< (abs (- (or (plist-get entry :fraction) 0.0)
                                   (or (plist-get record :fraction) 0.0)))
                           0.02))))
           (existing (seq-find same (etaf-weread--bookmarks-for app path)))
           (bookmark (list :path path
                           :chapter (plist-get record :chapter)
                           :fraction (plist-get record :fraction)
                           :text (or (etaf-weread--reader-line-text
                                      app (etaf-weread--read app :pane-scroll))
                                     "")
                           :at (float-time))))
      (setf (plist-get app :bookmarks)
            (if existing
                (seq-remove same (plist-get app :bookmarks))
              (seq-take (cons bookmark (plist-get app :bookmarks))
                        etaf-weread--bookmark-limit)))
      (etaf-weread--settings-write app)
      (etaf-weread--bookmarks-for app path))))

(defun etaf-weread-show-bookmark (app bookmark)
  "Show BOOKMARK in APP and return the chapter it lands in.
The chapter is exact and the position inside it comes from the stored
fraction, so a bookmark survives a different frame size or reading width."
  (let ((chapter (etaf-weread-read-chapter
                  app (1+ (or (plist-get bookmark :chapter) 0)))))
    (let* ((rows (max 1 (etaf-weread--pane-page-rows app)))
           (total (max 1 (etaf-weread--read app :pane-total)))
           (span (max 0 (- total rows)))
           (target (round (* (or (plist-get bookmark :fraction) 0.0) span))))
      (etaf-weread-scroll-pane app (- target (etaf-weread--read app :pane-scroll)))
      (etaf-weread--remember-position app)
      chapter)))

(defun etaf-weread-jump-to-percent (app percent)
  "Move APP to PERCENT (0-100) of its open local book.
The chapter covering PERCENT is shown and the position inside it follows the
rest of the percentage, so the progress bar a reader sees matches the place.
Return the chapter actually shown, counting from 1."
  (let* ((local (etaf-weread--read app :local))
         (chapters (length (plist-get local :chapters))))
    (when (zerop chapters)
      (signal 'etaf-weread-error '("先打开一本本地书")))
    (let* ((share (max 0.0 (min 100.0 (float percent))))
           (exact (* (/ share 100.0) chapters))
           (index (min (1- chapters) (floor exact)))
           (within (- exact index))
           (shown (etaf-weread-read-chapter app (1+ index)))
           (rows (max 1 (etaf-weread--pane-page-rows app)))
           (total (max 1 (etaf-weread--read app :pane-total)))
           (span (max 0 (- total rows))))
      (etaf-weread-scroll-pane app (round (* within span)))
      shown)))

(defun etaf-weread-search-local-book (app keyword)
  "Return APP's local book matches for KEYWORD, in reading order.
Each match is (:chapter INDEX :title TITLE :needle NEEDLE :text EXCERPT), with
INDEX counting from 0; an empty KEYWORD signals `etaf-weread-error'.  At most
`etaf-weread--search-match-limit' matches are returned, so searching a long
book stays cheap."
  (let ((needle (string-trim (or keyword ""))))
    (when (string-empty-p needle)
      (signal 'etaf-weread-error '("搜索关键词不能为空")))
    (let* ((chapters (plist-get (etaf-weread--read app :local) :chapters))
           (index -1)
           (matches nil))
      (dolist (chapter chapters)
        (cl-incf index)
        (let* ((text (or (plist-get chapter :text) ""))
               (position 0))
          (while (and (< position (length text))
                      (< (length matches) etaf-weread--search-match-limit))
            (let ((hit (string-match (regexp-quote needle) text position)))
              (if (not hit)
                  (setq position (length text))
                (push (list :chapter index
                            :title (or (plist-get chapter :title) "")
                            :needle needle
                            :text (substring text
                                             (max 0 (- hit 12))
                                             (min (length text) (+ hit 28))))
                      matches)
                (setq position (+ hit (max 1 (length needle)))))))))
      (nreverse matches))))

(defun etaf-weread-show-match (app match)
  "Show MATCH in APP and scroll until the match is on screen.
Return the chapter it lands in, counting from 1."
  (let ((chapter (etaf-weread-read-chapter app (1+ (or (plist-get match :chapter) 0)))))
    (let* ((needle (or (plist-get match :needle) ""))
           (lines (etaf-weread--read app :reader-lines))
           (rows (max 1 (etaf-weread--pane-page-rows app)))
           (index 0)
           (found nil))
      (while (and lines (< index (length lines)) (not found))
        (when (string-match-p (regexp-quote needle)
                              (or (plist-get (nth index lines) :text) ""))
          (setq found index))
        (cl-incf index))
      (when found
        (etaf-weread-scroll-pane
         app (- (max 0 (- found (/ rows 3)))
                (etaf-weread--read app :pane-scroll))))
      (etaf-weread--remember-position app)
      chapter)))

(defun etaf-weread--visible-line-text (app)
  "Return the first non-blank line APP's reading pane shows, or nil."
  (let* ((lines (or (etaf-weread--read app :reader-lines) nil))
         (start (max 0 (min (etaf-weread--read app :pane-scroll)
                            (max 0 (1- (length lines))))))
         (rows (max 1 (etaf-weread--pane-page-rows app)))
         (slice (seq-subseq lines start (min (length lines) (+ start rows)))))
    (seq-some (lambda (line)
                (let ((text (string-trim (or (plist-get line :text) ""))))
                  (unless (string-empty-p text) text)))
              slice)))

(defun etaf-weread--lookup-text (app)
  "Return what APP's dictionary key should look up.
The selected text wins; otherwise the line at the top of the visible chapter
is the line being read.  Return nil when there is nothing to look up."
  (let ((buffer (plist-get app :buffer)))
    (or (and (buffer-live-p buffer)
             (with-current-buffer buffer
               (when (use-region-p)
                 (let ((text (string-trim
                              (buffer-substring-no-properties
                               (region-beginning) (region-end)))))
                   (unless (string-empty-p text) text)))))
        (etaf-weread--visible-line-text app))))

(defun etaf-weread-lookup (app &optional query)
  "Look QUERY up with `etaf-weread-dictionary-function' and return the text.
QUERY defaults to the selected text, or while reading to the line at the top
of the visible chapter.  `etaf-weread-error' signals when there is nothing to
look up or the backend is missing; a backend that needs the network does its
own reporting."
  (let ((text (string-trim (or query (or (etaf-weread--lookup-text app) "")))))
    (when (string-empty-p text)
      (signal 'etaf-weread-error '("没有可查的词：先打开一本本地书，或选中一段文字")))
    (funcall etaf-weread-dictionary-function text)
    text))

(defun etaf-weread--match-key (string)
  "Return STRING without spaces or punctuation, for title matching."
  (replace-regexp-in-string "[[:space:][:punct:]]" "" (or string "")))

(defun etaf-weread--compact-text (string)
  "Return STRING with all whitespace removed, for cross-edition matching.
A highlight may span a wrap point and editions differ in spacing, so the
comparison drops whitespace before looking for it."
  (replace-regexp-in-string "[[:space:]]+" "" (or string "")))

(defun etaf-weread--match-local-title (app rows)
  "Return the notebook ROW of APP's open local book, or nil.
The title is compared without spaces or punctuation first, and a containment
in either direction counts as a second chance."
  (let* ((local (etaf-weread--read app :local))
         (title (etaf-weread--match-key (plist-get local :title))))
    (when (> (length title) 1)
      (or (seq-find (lambda (row)
                      (equal title
                             (etaf-weread--match-key (plist-get row :title))))
                    rows)
          (seq-find (lambda (row)
                      (let ((candidate (etaf-weread--match-key (plist-get row :title))))
                        (and (> (length candidate) 1)
                             (or (string-match-p (regexp-quote title) candidate)
                                 (string-match-p (regexp-quote candidate) title)))))
                    rows)))))

(defun etaf-weread--chapter-find (chapters text)
  "Return the index of the chapter of CHAPTERS containing TEXT, or nil."
  (let ((needle (etaf-weread--compact-text text)))
    (when (> (length needle) 1)
      (cl-position-if (lambda (chapter)
                        (string-match-p
                         (regexp-quote needle)
                         (etaf-weread--compact-text (plist-get chapter :text))))
                      chapters))))

(defun etaf-weread--local-note-matches (app notes)
  "Return the highlights of NOTES that APP's open local book contains.
Each match is (:id :chapter INDEX :text :thought); a highlight whose text is
not in the local text is skipped, because another edition may have rewritten
it or the passage may be missing entirely."
  (let* ((chapters (plist-get (etaf-weread--read app :local) :chapters))
         (matches nil))
    (dolist (group (plist-get notes :groups))
      (dolist (item (plist-get group :items))
        (let ((text (string-trim (or (plist-get item :text) ""))))
          (when-let* ((index (etaf-weread--chapter-find chapters text)))
            (setq matches
                  (append matches
                          (list (list :id (plist-get item :id)
                                      :chapter index
                                      :text text
                                      :thought (plist-get item :thought)))))))))
    matches))

(defun etaf-weread--chapter-notes (app index)
  "Return APP's matched highlights that land in chapter INDEX."
  (let ((notes (etaf-weread--read app :local-notes)))
    (seq-filter (lambda (note) (equal index (plist-get note :chapter)))
                (plist-get notes :notes))))

(defun etaf-weread--note-line-indices (lines notes)
  "Return the indices of LINES that any of NOTES covers.
The line texts are joined into one whitespace-free string, so a highlight
that spans a wrap point still marks every line it crosses."
  (let ((joined (mapconcat (lambda (line)
                             (etaf-weread--compact-text (plist-get line :text)))
                           lines ""))
        (spans nil))
    (dolist (note notes)
      (let* ((needle (etaf-weread--compact-text (plist-get note :text)))
             (position (and (> (length needle) 1)
                            (string-match (regexp-quote needle) joined))))
        (when position
          (push (cons position (+ position (length needle))) spans))))
    (let ((offset 0)
          (index 0)
          (covered nil))
      (dolist (line lines)
        (let* ((text (etaf-weread--compact-text (plist-get line :text)))
               (start offset)
               (end (+ offset (length text))))
          (when (seq-some (lambda (span)
                            (and (< start (cdr span)) (> end (car span))))
                          spans)
            (push index covered))
          (setq offset end
                index (1+ index))))
      (nreverse covered))))

(defun etaf-weread--bindings-from-data (data)
  "Return the local-book bindings of backend reply DATA as plists.
Each binding is (:file :book-id :title :source :percent :chapter-idx
:chapter-offset :reading-time).  PERCENT is the account's progress of the
bound book, or 0 when the account never opened it."
  (mapcar
   (lambda (binding)
     (let ((progress (plist-get binding :progress)))
       (list :file (etaf-weread--string (plist-get binding :file))
             :book-id (etaf-weread--string (plist-get binding :book_id))
             :title (etaf-weread--string (plist-get binding :title))
             :source (etaf-weread--string (plist-get binding :source))
             :percent (etaf-weread--required-number (plist-get progress :percent))
             :chapter-idx (plist-get progress :chapter_idx)
             :chapter-offset (plist-get progress :chapter_offset)
             :reading-time (etaf-weread--required-number (plist-get progress :reading_time)))))
   (etaf-weread--list (plist-get (etaf-weread--payload data) :bindings))))

(defun etaf-weread--binding-for (app path)
  "Return APP's binding of the local book at PATH, or nil."
  (when path
    (seq-find (lambda (binding)
                (equal (plist-get binding :file) (etaf-weread--string path)))
              (etaf-weread--read app :local-bindings))))

(defun etaf-weread--cloud-progress (app)
  "Return the account progress percent of APP's open local book, or nil."
  (let* ((path (plist-get (etaf-weread--read app :local) :path))
         (binding (and path (etaf-weread--binding-for app path)))
         (percent (plist-get binding :percent)))
    (and (numberp percent) (> percent 0) percent)))

(defun etaf-weread--apply-local-bindings (app)
  "Give every bound local row the account's progress of its book.
Rows keep that percent in `:progress', so the list meter reads as how far the
account is; a local book without a binding keeps a zero meter."
  (let ((rows (etaf-weread--read app :rows)))
    (when (and rows (seq-some (lambda (row) (plist-get row :local)) rows))
      (etaf-weread--write
       app :rows
       (mapcar (lambda (row)
                 (if (plist-get row :local)
                     (let* ((binding (etaf-weread--binding-for app (plist-get row :id)))
                            (copy (copy-sequence row)))
                       (plist-put copy :progress (or (plist-get binding :percent) 0))
                       copy)
                   row))
               rows)))))

(defun etaf-weread--local-bindings-load (app &optional then)
  "Load APP's local-book bindings, publish them and decorate the local rows.
THEN runs after the reply was applied, and also when the request failed, so a
caller that falls back to title matching is never left waiting."
  (etaf-weread--call
   app (list :op :bind)
   :on-ok (lambda (data)
            (etaf-weread--write app :local-bindings
                                (etaf-weread--bindings-from-data data))
            (etaf-weread--apply-local-bindings app)
            (when then (funcall then)))
   :on-error (lambda (&rest _) (when then (funcall then)))))

(defun etaf-weread--publish-local-notes (app book-id title data)
  "Match DATA's highlights to APP's open local book and publish them."
  (let* ((notes (etaf-weread--notes-from-data data book-id))
         (matches (etaf-weread--local-note-matches app notes)))
    (etaf-weread--write app :local-notes
                        (list :book-id book-id :title title :notes matches))
    (etaf-weread--publish-local-chapter app)
    (etaf-weread--note
     app (if matches
             (format "已叠加《%s》的 %d 处划线/想法（N 下一条）" title (length matches))
           (format "《%s》的笔记与本地文本没有重合" title)))))

(defun etaf-weread-match-local-notes (app &optional refresh)
  "Match APP's account highlights to its open local book and return them.
A binding for the local file pins the account book; without one the local
title is looked up in the notebook and the highlights of the best match are
kept when their text appears in the local chapters, so a different edition
only contributes the passages it shares.  The result is published as the
session state's `:local-notes' and holds `:book-id', `:title' and `:notes',
each note carrying `:id', `:chapter', `:text' and `:thought'.
REFRESH non-nil fetches again.  The requests are asynchronous, so a nil
return means the reply has not arrived yet; a scripted client replies at
once.  A session without an open local book signals `etaf-weread-error'."
  (unless (plist-get (etaf-weread--read app :local) :path)
    (signal 'etaf-weread-error '("先打开一本本地书")))
  (when (or refresh (null (etaf-weread--read app :local-notes)))
    (setf (plist-get app :local-note-id) nil)
    (etaf-weread--write app :local-notes (list :book-id nil :title nil :notes nil))
    (let* ((local (etaf-weread--read app :local))
           (binding (etaf-weread--binding-for app (plist-get local :path))))
      (if (and binding (not (string-empty-p (or (plist-get binding :book-id) ""))))
          (let ((book-id (plist-get binding :book-id))
                (title (or (plist-get binding :title) (plist-get local :title))))
            (etaf-weread--call
             app (list :op :notes :id book-id)
             :on-ok (lambda (data)
                      (etaf-weread--publish-local-notes app book-id title data))))
        (etaf-weread--call
         app (list :op :notebook)
         :on-ok (lambda (data)
                  (let* ((request (list :op :notebook))
                         (rows (etaf-weread--rows-for app request data))
                         (row (etaf-weread--match-local-title app rows)))
                    (if (null row)
                        (etaf-weread--note
                         app (format "微信读书笔记本里没有找到《%s》"
                                     (or (plist-get local :title) "这本书")))
                      (etaf-weread--call
                       app (list :op :notes :id (plist-get row :id))
                       :on-ok (lambda (notes-data)
                                (etaf-weread--publish-local-notes
                                 app (plist-get row :id) (plist-get row :title)
                                 notes-data))))))))))
  (etaf-weread--read app :local-notes))

(defun etaf-weread-sync-progress (app)
  "Write APP's reading place of the open local book back to WeChat Reading.
The account's copy is updated by the official web reader, which the weread
skill drives in the controlled browser; this asks for confirmation first.  A
local book without a binding signals `etaf-weread-error'.  Return non-nil when
a sync was requested.  The reply refreshes the published binding."
  (let* ((local (etaf-weread--read app :local))
         (path (plist-get local :path)))
    (unless path
      (signal 'etaf-weread-error '("先打开一本本地书")))
    (let ((binding (etaf-weread--binding-for app path)))
      (unless (and binding (not (string-empty-p (or (plist-get binding :book-id) ""))))
        (signal 'etaf-weread-error
                (list (format "《%s》还没绑定微信读书；先跑 pi-skill weread bind set"
                              (or (plist-get local :title) "这本本地书")))))
      (if (not (y-or-n-p (format "把《%s》的本地进度同步到微信读书？"
                                 (or (plist-get local :title) "这本本地书"))))
          (progn (etaf-weread--note app "已取消同步") nil)
        (let* ((chapters (plist-get local :chapters))
               (index (or (plist-get local :index) 0))
               (chapter (nth index chapters))
               (percent (or (etaf-weread--read app :reader-progress) 0)))
          (etaf-weread--note app "正在把进度同步到微信读书…")
          (etaf-weread--call
           app (list :op :sync-progress :file path
                     :chapter-title (or (plist-get chapter :title) "")
                     :percent percent :yes t :timeout 120)
           :on-ok
           (lambda (data)
             (let* ((payload (etaf-weread--payload data))
                    (cloud (etaf-weread--required-number (plist-get payload :progress)))
                    (chapter-idx (plist-get payload :chapter_idx)))
               (etaf-weread--write
                app :local-bindings
                (mapcar
                 (lambda (item)
                   (if (equal (plist-get item :file) (etaf-weread--string path))
                       (let ((copy (copy-sequence item)))
                         (plist-put copy :percent cloud)
                         (plist-put copy :chapter-idx chapter-idx)
                         copy)
                     item))
                 (etaf-weread--read app :local-bindings)))
               (etaf-weread--apply-local-bindings app)
               (etaf-weread--note
                app (format "已同步到微信读书：第 %s 章 · 云端 %d%%"
                            (or chapter-idx (1+ index)) cloud)))))
          t)))))

(defun etaf-weread-show-local-note (app note)
  "Show NOTE in APP and return the chapter it lands in.
The chapter is read again and the view scrolls until the note's text is
visible; the thought attached to the highlight is reported in the status
line."
  (let* ((chapter (etaf-weread-read-chapter app (1+ (or (plist-get note :chapter) 0))))
         (lines (etaf-weread--read app :reader-lines))
         (rows (max 1 (etaf-weread--pane-page-rows app)))
         (index (car (etaf-weread--note-line-indices lines (list note)))))
    (when index
      (etaf-weread-scroll-pane
       app (- (max 0 (- index (/ rows 3)))
              (etaf-weread--read app :pane-scroll)))
      (etaf-weread--remember-position app))
    ;; `N' walks on from the note that was just shown, not from the scroll
    ;; position, so showing a note twice does not trap the reader.
    (setf (plist-get app :local-note-id) (plist-get note :id))
    (etaf-weread--note
     app (format "笔记：%s"
                 (let ((thought (etaf-weread--string (plist-get note :thought))))
                   (if (string-empty-p thought) (plist-get note :text) thought))))
    chapter))

(defun etaf-weread-next-local-note (app)
  "Show the next matched highlight after the one just shown and return it.
The search wraps: after the last match it continues with the first one.  A
session without matched highlights returns nil."
  (let* ((notes (plist-get (etaf-weread--read app :local-notes) :notes))
         (local (etaf-weread--read app :local))
         (chapter (or (plist-get local :index) 0))
         (scroll (etaf-weread--read app :pane-scroll))
         (lines (etaf-weread--read app :reader-lines))
         (last (plist-get app :local-note-id))
         (ordered
          (seq-sort
           (lambda (a b)
             (or (< (nth 0 a) (nth 0 b))
                 (and (= (nth 0 a) (nth 0 b)) (< (nth 1 a) (nth 1 b)))))
           (mapcar (lambda (note)
                     (list (or (plist-get note :chapter) 0)
                           (or (car (etaf-weread--note-line-indices lines (list note))) 0)
                           note))
                   notes))))
    (when ordered
      (let* ((rest (when last
                     (cdr (seq-drop-while
                           (lambda (entry)
                             (not (equal last (plist-get (nth 2 entry) :id))))
                           ordered))))
             (next (if last
                       ;; After the last match the walk wraps to the first.
                       (or (car rest) (car ordered))
                     ;; No note shown yet: take the first one after the
                     ;; reading place, else wrap.
                     (or (seq-find (lambda (entry)
                                     (or (> (nth 0 entry) chapter)
                                         (and (= (nth 0 entry) chapter)
                                              (> (nth 1 entry) scroll))))
                                   ordered)
                         (car ordered)))))
        (etaf-weread-show-local-note app (nth 2 next))
        (nth 2 next)))))

(defun etaf-weread-read-chapter (app index)
  "Show chapter INDEX (counting from 1) of APP's opened local book.
INDEX is clamped into range and a session without a local book does nothing.
Return the chapter index actually shown."
  (let* ((local (etaf-weread--read app :local))
         (chapters (plist-get local :chapters)))
    (when chapters
      (let ((next (max 0 (min (1- (length chapters)) (1- (max 1 index))))))
        ;; The time belongs to the chapter just left.
        (etaf-weread--reading-accumulate app)
        (etaf-batch
          (setf (plist-get local :index) next)
          (etaf-weread--write app :local local)
          (etaf-weread--write app :pane-scroll 0))
        (etaf-weread--publish-local-chapter app)
        ;; The reader pane is on screen now, so the canvas and row budget
        ;; follow the reading font before the position is stored.
        (etaf-weread--sync-layout app)
        (etaf-weread--reading-begin app)
        (etaf-weread--remember-position app)
        (1+ next)))))

(defun etaf-weread-toggle-zen (app)
  "Toggle APP's reading-only layout and return the new value.
The reading-only layout hides the section navigation, the running hint and the
footer, so the open local chapter owns the frame; the reading column keeps its
width and stays centered.  A session that is not showing a local chapter stays
as it is, because there is nothing to read in zen, and nil is returned."
  (when (eq (etaf-weread--effective-pane app) 'reader)
    (let ((zen (not (etaf-weread--read app :zen))))
      (etaf-weread--write app :zen zen)
      (etaf-weread--sync-layout app)
      (etaf-weread--note app (if zen
                                 "阅读模式：f 返回 · [ ] 留白 · T 主题"
                               "已退出阅读模式"))
      zen)))

(defun etaf-weread--cancel-auto-scroll (app)
  "Stop APP's auto-scroll timer and clear its reading.
The timer is the only owner of a running auto-scroll, so canceling is also
what a disposal and leaving the reading pane do."
  (when-let* ((timer (plist-get app :auto-scroll-timer)))
    (cancel-timer timer)
    (setf (plist-get app :auto-scroll-timer) nil))
  (etaf-weread--write app :auto-scroll nil))

(defun etaf-weread--auto-scroll-tick (app)
  "Advance APP one reading line and turn the chapter when it ends.
The tick is the only place a running auto-scroll moves, so it is bounded by
the book: the last line of the last chapter stops it.  A session that was
disposed, turned auto-scroll off, or left the reading pane while the timer
was pending cancels the timer here instead of scrolling something invisible."
  (if (or (plist-get app :disposed)
          (not (etaf-weread--read app :auto-scroll))
          (not (eq (etaf-weread--effective-pane app) 'reader)))
      (etaf-weread--cancel-auto-scroll app)
    (let ((before (etaf-weread--read app :pane-scroll)))
      (etaf-weread-scroll-pane app 1)
      (when (= before (etaf-weread--read app :pane-scroll))
        (let* ((local (etaf-weread--read app :local))
               (index (or (plist-get local :index) 0))
               (chapters (length (plist-get local :chapters))))
          (if (< (1+ index) chapters)
              (etaf-weread-read-chapter app (+ index 2))
            (etaf-weread--cancel-auto-scroll app)
            (etaf-weread--note app "已读到最后，自动滚动停止")))))))

(defun etaf-weread-toggle-auto-scroll (app)
  "Toggle APP's auto-scroll and return the new value.
While it runs, one reading line is advanced every
`etaf-weread-auto-scroll-interval' seconds; a chapter that ends turns to the
next one, and the last line of the book stops it.  A session that is not
showing a local chapter does nothing and returns nil, because there is
nothing to scroll.  The timer is released when auto-scroll stops, when the
session is disposed and when the reading pane is left."
  (when (eq (etaf-weread--effective-pane app) 'reader)
    (let ((on (not (etaf-weread--read app :auto-scroll))))
      (if on
          (progn
            (etaf-weread--write app :auto-scroll t)
            (setf (plist-get app :auto-scroll-timer)
                  (run-at-time etaf-weread-auto-scroll-interval
                               etaf-weread-auto-scroll-interval
                               #'etaf-weread--auto-scroll-tick app))
            (etaf-weread--note
             app (format "自动滚动：每 %g 秒一行（a 停止）"
                         etaf-weread-auto-scroll-interval))
            t)
        (etaf-weread--cancel-auto-scroll app)
        (etaf-weread--note app "自动滚动：已停止")
        nil))))

(defun etaf-weread-adjust-reading-measure (app delta)
  "Widen APP's reading column by DELTA columns and return its new width.
The width stays inside the readable range, an open chapter is wrapped again
so every line still fits, and the choice is stored for the next session."
  (let ((width (max etaf-weread--reading-min-columns
                    (min etaf-weread--reading-max-columns
                         (+ (etaf-weread--read app :reader-measure) delta)))))
    (etaf-weread--write app :reader-measure width)
    (etaf-weread--sync-layout app)
    (etaf-weread--settings-write app)
    (let ((columns (etaf-weread--reading-columns app)))
      (etaf-weread--note app (format "阅读宽度：%d 列" columns))
      columns)))

(defun etaf-weread-toggle-reading-spread (app)
  "Show the next reading column count in APP and return the choice.
The order is automatic, then one column, two and so on up to what the pane can
hold, and back to automatic; the session state's `:reader-shown' reports what
is actually on screen.  The choice is stored for the next session."
  (let* ((fit (etaf-weread--reader-fit (etaf-weread--read app :reader-capacity)
                                       (etaf-weread--read app :reader-columns)))
         (feasible (cons 'auto (number-sequence 1 fit)))
         (current (etaf-weread--read app :reader-spread))
         (index (or (cl-position current feasible :test #'equal) 0))
         (choice (or (nth (1+ index) feasible) 'auto)))
    (etaf-weread--write app :reader-spread choice)
    (etaf-weread--sync-layout app)
    (etaf-weread--settings-write app)
    (etaf-weread--note app (format "阅读栏数：%s（当前 %d 栏）"
                                   (if (eq choice 'auto) "自动" choice)
                                   (etaf-weread--read app :reader-shown)))
    choice))

(defun etaf-weread-reading-stats (app &optional path)
  "Return how much APP has read PATH, or its open local book.
The value is a plist with `:path', `:seconds' (total reading time),
`:chapters' (the chapter indices opened, newest first, at most
`etaf-weread--reading-chapter-limit') and `:at' (when it was last read).  A
book without a record returns nil, and PATH defaults to the open local book.
Only `etaf-weread-track-reading-time' collects the records."
  (let ((path (or path (plist-get (etaf-weread--read app :local) :path))))
    (and path
         (seq-find (lambda (entry) (equal (plist-get entry :path) path))
                   (plist-get app :reading)))))

(defun etaf-weread--reading-accumulate (app)
  "Add the time APP has been reading to its book's record and store it.
Called on every settled scroll, chapter turn, leave and close, so the record
never loses more than the last quiet moment.  A session that is not reading a
local book does nothing."
  (when (and etaf-weread-track-reading-time
             (plist-get app :reading-path)
             (plist-get app :reading-since))
    (let* ((path (plist-get app :reading-path))
           (elapsed (max 0 (- (float-time) (plist-get app :reading-since))))
           (visited (plist-get app :reading-visited))
           (kept (seq-remove (lambda (entry)
                               (equal (plist-get entry :path) path))
                             (plist-get app :reading)))
           (previous (seq-find (lambda (entry)
                                 (equal (plist-get entry :path) path))
                               (plist-get app :reading)))
           (chapters (seq-uniq (append visited (plist-get previous :chapters)))))
      (setf (plist-get app :reading)
            (seq-take (cons (list :path path
                                  :seconds (+ (or (plist-get previous :seconds) 0)
                                              elapsed)
                                  :chapters (seq-take chapters
                                                      etaf-weread--reading-chapter-limit)
                                  :at (float-time))
                            kept)
                      etaf-weread--reading-limit)
            (plist-get app :reading-since) (float-time))
      (etaf-weread--settings-write app))))

(defun etaf-weread--reading-begin (app)
  "Start tracking reading time for APP's open local book.
Switching to another book stores the previous one first and writes the new
record at once, resuming after a pause only restarts the clock, and the
chapter that is open now counts as visited."
  (when etaf-weread-track-reading-time
    (let* ((local (etaf-weread--read app :local))
           (path (plist-get local :path))
           (index (plist-get local :index)))
      (when path
        (let* ((new-book (not (equal path (plist-get app :reading-path))))
               (new-chapter (not (equal (car (plist-get app :reading-visited))
                                        index))))
          (when (and new-book (plist-get app :reading-path))
            (etaf-weread--reading-accumulate app))
          (when new-book
            (setf (plist-get app :reading-path) path
                  (plist-get app :reading-visited) nil))
          (setf (plist-get app :reading-since)
                (or (plist-get app :reading-since) (float-time)))
          (when new-chapter
            (setf (plist-get app :reading-visited)
                  (seq-take (cons index (delete index (plist-get app :reading-visited)))
                            etaf-weread--reading-chapter-limit)))
          (when (or new-book new-chapter)
            (etaf-weread--reading-accumulate app)))))))

(defun etaf-weread--reading-pause (app)
  "Stop counting reading time while APP shows something else.
The book and the chapters seen so far stay remembered, so opening the reader
again resumes the same record."
  (etaf-weread--reading-accumulate app)
  (setf (plist-get app :reading-since) nil))

(defun etaf-weread--reading-note (app)
  "Report APP's accumulated reading of the open book in the status line.
A book that was read before reports its stored time and chapter count; a new
one only says that reading started."
  (let* ((local (etaf-weread--read app :local))
         (stats (etaf-weread-reading-stats app))
         (title (or (plist-get local :title) "本地书")))
    (etaf-weread--note
     app (let ((duration (and stats
                              (etaf-weread-format-duration
                               (plist-get stats :seconds)))))
           (if (and duration (not (string-empty-p duration)))
               (format "%s · 已读 %s · %d 章"
                       title duration
                       (length (or (plist-get stats :chapters) nil)))
             (format "%s · 开始阅读" title))))))

(defun etaf-weread--reader-font-label (font)
  "Return the status-line name of the reading FONT preset."
  (pcase font
    ('small "小")
    ('large "大")
    (_ "中")))

(defun etaf-weread-set-reading-font (app font)
  "Set APP's reading font preset to FONT and return it.
FONT is `small', `medium' or `large'; any other value signals
`etaf-weread-error' and leaves APP unchanged.  `medium' keeps the frame's own
font, while a scaled preset wraps the open chapter again when the new size
changes how many columns fit, so no line clips.  The choice is stored in
`etaf-weread-settings-file'."
  (unless (memq font etaf-weread--reader-fonts)
    (signal 'etaf-weread-error
            (list (format "未知阅读字号：%s" font))))
  (etaf-weread--write app :reader-font font)
  (etaf-weread--sync-layout app)
  (etaf-weread--settings-write app)
  (etaf-weread--note app (format "阅读字号：%s"
                                 (etaf-weread--reader-font-label font)))
  font)

(defun etaf-weread-cycle-reading-font (app)
  "Show the next reading font preset in APP and return the choice.
The order is `small', `medium', `large' and back to `small'; the choice is
stored in `etaf-weread-settings-file' so the next session starts with it."
  (let* ((current (etaf-weread--read app :reader-font))
         (rest (cdr (memq current etaf-weread--reader-fonts)))
         (choice (or (car rest) (car etaf-weread--reader-fonts))))
    (etaf-weread-set-reading-font app choice)))

(defun etaf-weread-cycle-theme (app)
  "Switch APP to the next appearance and return it.
The order is `dark', `light' then `sepia'; the choice is stored in
`etaf-weread-settings-file' so the next session starts with it."
  (let* ((order '(dark light sepia))
         (mode (or (cadr (memq etaf-weread-theme-mode order)) 'dark)))
    (setq etaf-weread-theme-mode mode)
    (etaf-weread--write app :theme (etaf-weread-theme-defaults mode))
    (etaf-weread--settings-write app)
    (etaf-weread--note app (format "外观：%s"
                                   (pcase mode
                                     ('dark "深色")
                                     ('light "浅色")
                                     (_ "纸色"))))
    mode))

(defun etaf-weread-search (app keyword)
  "Search the WeChat Reading store for KEYWORD and show the matches.
KEYWORD is trimmed; an empty keyword signals `etaf-weread-error' instead of
querying the backend."
  (let ((keyword (string-trim (or keyword ""))))
    (when (string-empty-p keyword)
      (signal 'etaf-weread-error '("搜索关键词不能为空")))
    (let* ((key (list :search keyword))
           (same-p (equal key (plist-get app :list-key))))
      (etaf-batch
        (etaf-weread--write app :section :search)
        (etaf-weread--write app :mode 'search)
        (etaf-weread--write app :query keyword)
        (etaf-weread--write app :title "搜索结果")
        (etaf-weread--write app :subtitle (format "关键词：%s" keyword))
        (etaf-weread--write app :pane-scroll 0)
        (etaf-weread--show-list-pane app)
        (setf (plist-get app :list-key) key)
        (etaf-weread--show-cached-list app key same-p))
      (etaf-weread--load-list app key (etaf-weread--list-request app :search)
                              same-p (and (etaf-weread--list-entry app key) t)))))

(defun etaf-weread--list-key (app section)
  "Return the cache key of SECTION in APP.
A search section keys on its stored query, so a new keyword is a new list."
  (pcase section
    (:index (list :index))
    (:search (list :search (etaf-weread--read app :query)))
    (_ (list section))))

(defun etaf-weread--list-request (app section)
  "Return the backend request for SECTION in APP."
  (pcase section
    (:notebook (list :op :notebook :limit etaf-weread-list-limit))
    (:search (list :op :search :keyword (etaf-weread--read app :query)
                   :count etaf-weread-search-count))
    (:stats (list :op :stats))
    (:index nil)
    (_ (list :op :shelf :filter (etaf-weread--shelf-filter section)
             :limit etaf-weread-list-limit))))

(defconst etaf-weread--cached-sections
  '(:shelf :reading :finished :notebook :stats)
  "Sections whose lists live in the session's list cache.
Search, the local library and the highlight index have their own stores.")

(defun etaf-weread--cache-candidate (app now)
  "Return the (SECTION KEY REQUEST) to refresh in the background, or nil.
The stalest cached list comes first; when every cached list is still fresh,
one list that was never loaded is warmed so opening its section can use the
cache.  `etaf-list-cache' owns that order, the freshness interval and the
one-at-a-time rule; this function only maps a section to its request."
  (when (and etaf-weread-prefetch-lists
             (not (plist-get app :disposed))
             (etaf-weread--cache-visible-p app)
             (not (etaf-weread--read app :loading)))
    (let* ((pairs (cl-loop for section in etaf-weread--cached-sections
                           collect (cons (etaf-weread--list-key app section)
                                         section)))
           (key (etaf-list-cache-next (plist-get app :list-cache)
                                      (mapcar #'car pairs)
                                      now etaf-weread-library-refresh-interval)))
      (when key
        (let ((section (cdr (assq key pairs))))
          (list section key (etaf-weread--list-request app section)))))))

(defun etaf-weread--cache-visible-p (app)
  "Return non-nil when APP's buffer can be seen, or the session is headless.
A mounted reader that no window shows pauses its background refreshes: nobody
is looking at it, so the network and CPU can wait until it is shown again."
  (let ((buffer (plist-get app :buffer)))
    (or (null buffer)
        (and (buffer-live-p buffer)
             (get-buffer-window buffer t)))))

(defun etaf-weread--prefetch-list (app)
  "Refresh one cached list of APP in the background when one is due.
The refresh uses the ordinary load path, so a changed reply repaints the
section it belongs to and an unchanged reply leaves the page alone."
  (when-let* ((candidate (etaf-weread--cache-candidate app (float-time))))
    (etaf-weread--load-list app (nth 1 candidate) (nth 2 candidate) t t)))

(defun etaf-weread--schedule-prefetch (app)
  "Arm APP's idle cache refresh, replacing any timer already armed."
  (when etaf-weread-prefetch-lists
    (etaf-list-cache-arm (plist-get app :list-cache)
                         (lambda ()
                           (unless (plist-get app :disposed)
                             (etaf-weread--prefetch-list app)))
                         :interval etaf-weread-prefetch-interval)))

(defun etaf-weread--list-entry (app key)
  "Return APP's cached list for KEY, or nil."
  (etaf-list-cache-entry (plist-get app :list-cache) key))

(defun etaf-weread--store-list (app key rows total)
  "Cache ROWS and TOTAL for KEY in APP."
  (etaf-list-cache-put (plist-get app :list-cache) key rows total))

(defun etaf-weread--show-cached-list (app key keep-position-p)
  "Show APP's cached rows for KEY when one exists, without a loading state.
KEEP-POSITION-P leaves the reader where they are, for a refresh of the list
they are already looking at."
  (let ((entry (etaf-weread--list-entry app key)))
    (etaf-batch
      (etaf-weread--write app :rows (plist-get entry :rows))
      (etaf-weread--write app :list-total (or (plist-get entry :total) 0))
      (if keep-position-p
          (etaf-weread--clamp-list-position app)
        (etaf-weread--write app :selection 0)
        (etaf-weread--write app :window-start 0))
      (etaf-weread--write app :loading nil))))

(defun etaf-weread--clamp-list-position (app)
  "Keep APP's selection and page inside its current rows."
  (let* ((total (length (etaf-weread--read app :rows)))
         (size (max 1 (etaf-weread--read app :page-size))))
    (etaf-weread--write app :selection
                        (max 0 (min (max 0 (1- total))
                                    (etaf-weread--read app :selection))))
    (etaf-weread--write app :window-start
                        (max 0 (min (etaf-weread--read app :window-start)
                                    (max 0 (- total size)))))
    (etaf-weread--sync-pane-total app)))

(defun etaf-weread--load-list
    (app key request &optional keep-position-p background)
  "Load REQUEST for APP, caching its rows under KEY.
KEEP-POSITION-P keeps the position of a reload of the list the reader is
already looking at.  BACKGROUND is a refresh the reader did not ask for: it
shows no loading state, repaints only when the reply differs from the cache,
and never invalidates a visible load.  A reply belonging to an earlier load is
dropped."
  (let* ((generation
          (if background
              (plist-get app :generation)
            (setf (plist-get app :generation) (1+ (plist-get app :generation)))))
         (cache (plist-get app :list-cache))
         (previous (etaf-list-cache-entry cache key)))
    (when background
      (etaf-list-cache-set-busy cache t))
    (unless background
      (etaf-weread--write app :loading t)
      (etaf-weread--write app :error nil))
    (etaf-weread--call
     app request
     :on-ok (lambda (data)
              (when background
                (etaf-list-cache-set-busy cache nil))
              (etaf-list-cache-note-success cache)
              (let* ((rows (etaf-weread--rows-for app request data))
                     (total (or (etaf-weread--parse-number (plist-get data :total))
                                (length rows)))
                     (unchanged (and previous
                                     (equal (plist-get previous :rows) rows)
                                     (equal (plist-get previous :total) total))))
                (etaf-list-cache-put cache key rows total)
                (when (and (= generation (plist-get app :generation))
                           (equal key (plist-get app :list-key)))
                  (if unchanged
                      ;; 内容没变：只收下新的时间戳，页面保持原样。
                      (etaf-weread--write app :loading nil)
                    (etaf-batch
                      (etaf-weread--write app :rows rows)
                      (etaf-weread--write app :list-total total)
                      (if keep-position-p
                          (etaf-weread--clamp-list-position app)
                        (etaf-weread--write app :selection 0)
                        (etaf-weread--write app :window-start 0))
                      (etaf-weread--write app :loading nil)
                      (etaf-weread--write app :summary
                                          (etaf-weread--list-summary app request data rows))
                      (etaf-weread--note app (etaf-weread--list-summary app request data rows)))
                    (etaf-weread--sync-pane-total app)
                    ;; The detail pane follows the settled selection; moving
                    ;; through the list never requests books passed over.
                    (when (etaf-weread--pane-shown-p app)
                      (etaf-weread--schedule-detail
                       app (etaf-weread--selected-id app)))))))
     :on-error (lambda (message _hint code)
                 (etaf-list-cache-note-failure cache code)
                 (when background
                   (etaf-list-cache-set-busy cache nil))
                 (when (and (= generation (plist-get app :generation))
                            (equal key (plist-get app :list-key))
                            (not background))
                   (etaf-weread--write app :loading nil)
                   (etaf-weread--write app :rows nil)
                   (etaf-weread--write app :list-total 0)
                   (etaf-weread--write app :summary "")
                   (etaf-weread--note app message))))))

(defun etaf-weread--rows-for (app request data)
  "Map backend DATA of REQUEST into APP's book rows."
  (let ((payload (etaf-weread--payload data)))
    (pcase (plist-get request :op)
      (:shelf (etaf-weread--book-rows (plist-get payload :shelf) :shelf))
      (:notebook (etaf-weread--book-rows (plist-get payload :books) :notebook))
      (:search (etaf-weread--book-rows (plist-get payload :books) :search))
      (:stats
       (etaf-weread--write app :stats (etaf-weread--stats-from-data data))
       (etaf-weread--book-rows (plist-get payload :top) :stats))
      (_ nil))))

(defun etaf-weread--book-rows (items source)
  "Return book plists ITEMS as list rows for SOURCE.
SOURCE is `:shelf', `:notebook', `:search' or `:stats' and selects the badge a
row carries; a book id is required, everything else is presentation."
  (cl-loop for item in (etaf-weread--list items)
           for id = (etaf-weread--string (plist-get item :bookId))
           when (not (string-empty-p id))
           collect (let* ((counts (plist-get item :counts))
                          (notes (etaf-weread--required-number (plist-get counts :notes)))
                          (reviews (etaf-weread--required-number
                                    (plist-get counts :reviews)))
                          (finished (etaf-weread--truthy-p (plist-get item :finished))))
                     (list :kind :book
                           :id id
                           :title (or (etaf-weread--string (plist-get item :title)) "未命名")
                           :author (etaf-weread--string (plist-get item :author))
                           :category (etaf-weread--string (plist-get item :category))
                           :cover (etaf-weread--string (plist-get item :cover))
                           :deep-link (etaf-weread--string (plist-get item :deepLink))
                           :progress (etaf-weread--required-number
                                      (plist-get item :progress))
                           :reading-time (etaf-weread--required-number
                                          (plist-get item :readingTime))
                           :rating (etaf-weread--parse-number (plist-get item :rating))
                           :finished finished
                           :notes notes
                           :reviews reviews
                           :in-shelf (etaf-weread--truthy-p (plist-get item :inShelf))
                           :badge (pcase source
                                    (:notebook (cond ((and (> notes 0) (> reviews 0))
                                                      (format "✎ %d · ✦ %d" notes reviews))
                                                     ((> notes 0) (format "✎ %d" notes))
                                                     ((> reviews 0) (format "✦ %d" reviews))
                                                     (t "")))
                                    (:search (etaf-weread--rating-text
                                              (plist-get item :rating)))
                                    (_ (cond (finished "读完")
                                             ((> notes 0) (format "✎ %d" notes))
                                             (t ""))))
                           :right (etaf-weread-format-duration
                                   (plist-get item :readingTime))))))

(defun etaf-weread--list-summary (app request data rows)
  "Return the status-line summary of DATA loaded for REQUEST in APP."
  (pcase (plist-get request :op)
    (:shelf (format "书架 %s 本 · 在读 %s · 读完 %s"
                    (or (etaf-weread--parse-number (plist-get data :books))
                        (length rows))
                    (or (etaf-weread--parse-number (plist-get data :reading)) 0)
                    (or (etaf-weread--parse-number (plist-get data :finished)) 0)))
    (:notebook (format "有笔记 %s 本 · 笔记 %s · 想法 %s"
                       (or (etaf-weread--parse-number (plist-get data :books))
                           (length rows))
                       (or (etaf-weread--parse-number (plist-get data :notes)) 0)
                       (or (etaf-weread--parse-number (plist-get data :reviews)) 0)))
    (:search (format "搜索「%s」· 展示了 %d 本"
                     (etaf-weread--read app :query) (length rows)))
    (:stats (let ((stats (etaf-weread--read app :stats)))
              (or (plist-get stats :conclusion)
                  (format "读得最多的 %d 本" (length rows)))))
    (_ "")))

;;; ---------------------------------------------------------------------------
;;; Book detail and highlights
;;; ---------------------------------------------------------------------------

(defun etaf-weread--selected-row (app)
  "Return the row APP's selection points at, or nil."
  (nth (etaf-weread--read app :selection) (etaf-weread--read app :rows)))

(defun etaf-weread--item-id (item)
  "Return the book id of ITEM, a row or an id string, or nil."
  (cond ((null item) nil)
        ((listp item) (let ((id (plist-get item :id)))
                        (and id (not (string-empty-p (format "%s" id)))
                             (format "%s" id))))
        ((stringp item) (unless (string-empty-p (string-trim item))
                          (string-trim item)))
        (t (format "%s" item))))

(defun etaf-weread--item-title (item)
  "Return the book title of ITEM, or an empty string."
  (if (listp item) (or (etaf-weread--string (plist-get item :title)) "") ""))

(defun etaf-weread--detail-id (app)
  "Return the book id APP's detail pane is about, or nil."
  (plist-get (etaf-value (etaf-weread--ref app :detail)) :id))

(defun etaf-weread--selected-id (app)
  "Return the book id APP's selection points at, or nil."
  (etaf-weread--item-id (etaf-weread--selected-row app)))

(defun etaf-weread-show-book (app item &optional pane)
  "Show the book ITEM in APP's side pane and load what is missing.
ITEM is a row or a book id.  PANE is `detail' (the default) or `notes'; the
notes pane always loads the highlights of the book.  Cached data is painted at
once; otherwise a loading placeholder appears and the request runs in the
background.  A missing book id signals `etaf-weread-error'."
  (let ((id (etaf-weread--item-id item)))
    (unless id
      (signal 'etaf-weread-error '("No book selected")))
    (let ((pane (or pane 'detail)))
      (unless (memq pane '(detail notes))
        (signal 'etaf-weread-error (list (format "Unknown pane: %S" pane))))
      (etaf-weread--write app :pane pane)
      (etaf-weread--write app :pane-scroll 0)
      (etaf-weread--publish-detail app id (etaf-weread--item-title item))
      (when (eq pane 'notes)
        (etaf-weread--publish-notes app id))
      (unless (gethash id (plist-get app :detail-cache))
        (etaf-weread--load-detail app id))
      (when (and (eq pane 'notes) (not (gethash id (plist-get app :notes-cache))))
        (etaf-weread--load-notes app id)))
    id))

(defun etaf-weread--local-row-p (row)
  "Return non-nil when list ROW is a local file rather than a store book."
  (and row (plist-get row :local)))

(defun etaf-weread--schedule-detail (app id)
  "Make APP's detail pane follow ID after a short quiet period.
A book whose detail is cached is painted immediately; otherwise the request is
delayed by `etaf-weread-detail-follow-delay', so fast browsing never asks the
backend about a book that was only passed over.  A local book's id is its file
path and it has no backend detail, so it is left alone instead of asking the
shelf about a path and painting a not-found error over the session."
  (when-let* ((timer (plist-get app :follow-timer)))
    (cancel-timer timer)
    (setf (plist-get app :follow-timer) nil))
  (when (and id
             (not (plist-get app :disposed))
             (not (etaf-weread--local-row-p (etaf-weread--selected-row app))))
    (if (gethash id (plist-get app :detail-cache))
        (etaf-weread--publish-detail app id)
      (etaf-weread--publish-detail app id nil)
      (setf (plist-get app :follow-timer)
            (run-at-time
             etaf-weread-detail-follow-delay nil
             (lambda ()
               (setf (plist-get app :follow-timer) nil)
               (when (and (not (plist-get app :disposed))
                          (equal id (etaf-weread--selected-id app))
                          (not (gethash id (plist-get app :detail-cache))))
                 (etaf-weread--load-detail app id))))))))

(defun etaf-weread--publish-detail (app id &optional title)
  "Publish APP's detail data for ID, using cached data when available.
TITLE is used for the loading placeholder before the book info arrives."
  (let ((detail (or (gethash id (plist-get app :detail-cache))
                    (list :id id :title (or title "") :loading t))))
    (etaf-weread--write app :detail detail)
    (etaf-weread--sync-pane-total app)))

(defun etaf-weread--publish-notes (app id)
  "Publish APP's highlights for ID, using cached data when available."
  (let ((notes (or (gethash id (plist-get app :notes-cache))
                   (list :id id :loading t))))
    (etaf-weread--write app :notes notes)
    (etaf-weread--sync-pane-total app)))

(defun etaf-weread--load-detail (app id)
  "Load book info, chapter list and counts of ID into APP.
A reply belonging to a superseded book is still cached but never painted."
  (let ((generation (cl-incf (plist-get app :detail-generation))))
    (etaf-weread--call
     app (list :op :book :id id)
     :on-ok (lambda (data)
              (let ((detail (etaf-weread--detail-from-data data id)))
                (puthash id detail (plist-get app :detail-cache))
                (when (and (= generation (plist-get app :detail-generation))
                           (equal id (etaf-weread--detail-id app)))
                  (etaf-weread--write app :detail detail)
                  (etaf-weread--sync-pane-total app)
                  (etaf-weread--note
                   app (format "%s · %d 章 · %s"
                               (or (plist-get detail :title) id)
                               (length (plist-get detail :chapters))
                               (if (plist-get detail :progress)
                                   (etaf-weread--progress-text (plist-get detail :progress))
                                 "未开始"))))))
     :on-error (lambda (message _hint _code)
                 (when (and (= generation (plist-get app :detail-generation))
                            (equal id (etaf-weread--detail-id app)))
                   (etaf-weread--write app :detail (list :id id :error message))
                   (etaf-weread--note app message))))))

(defun etaf-weread--load-notes (app id)
  "Load the highlights and thoughts of book ID into APP."
  (let ((generation (cl-incf (plist-get app :notes-generation))))
    (etaf-weread--call
     app (list :op :notes :id id)
     :on-ok (lambda (data)
              (let ((notes (etaf-weread--notes-from-data data id)))
                (puthash id notes (plist-get app :notes-cache))
                (when etaf-weread-index-on-read
                  (condition-case error
                      (etaf-weread--index-store app id notes)
                    (error (etaf-weread--note
                            app (format "索引写入失败：%s"
                                        (error-message-string error))))))
                (when (and (= generation (plist-get app :notes-generation))
                           (equal id (plist-get (etaf-value (etaf-weread--ref app :detail)) :id)))
                  (etaf-weread--write app :notes notes)
                  (etaf-weread--sync-pane-total app)
                  (etaf-weread--note app (format "「%s」划线与想法：%d 条"
                                                 (or (plist-get notes :title) id)
                                                 (or (plist-get notes :count) 0))))))
     :on-error (lambda (message _hint _code)
                 (when (and (= generation (plist-get app :notes-generation))
                            (equal id (plist-get (etaf-value (etaf-weread--ref app :detail)) :id)))
                   (etaf-weread--write app :notes (list :id id :error message))
                   (etaf-weread--note app message))))))

(defun etaf-weread--detail-from-data (data id)
  "Return the reader's detail plist built from backend DATA for book ID."
  (let* ((payload (etaf-weread--payload data))
         (book (plist-get payload :book))
         (progress (plist-get payload :progress))
         (counts (plist-get book :counts))
         (finished (etaf-weread--truthy-p (plist-get book :finished))))
    (list :id id
          :title (or (etaf-weread--string (plist-get book :title)) id)
          :author (etaf-weread--string (plist-get book :author))
          :category (etaf-weread--string (plist-get book :category))
          :rating (etaf-weread--rating-text (plist-get book :rating))
          :word-count (etaf-weread--required-number (plist-get book :wordCount))
          :progress (etaf-weread--required-number (plist-get progress :progress))
          :reading-time (etaf-weread--required-number (plist-get progress :readingTime))
          :notes (etaf-weread--required-number (plist-get counts :notes))
          :reviews (etaf-weread--required-number (plist-get counts :reviews))
          :bookmarks (etaf-weread--required-number (plist-get counts :bookmarks))
          :intro (etaf-weread--string (plist-get book :intro))
          :publisher (etaf-weread--string (plist-get book :publisher))
          :translator (etaf-weread--string (plist-get book :translator))
          :published (etaf-weread--string (plist-get book :publishTime))
          :deep-link (or (etaf-weread--string (plist-get book :deepLink))
                         (etaf-weread-reader-url id))
          :finished finished
          :chapters
          (cl-loop for chapter in (etaf-weread--list (plist-get payload :chapters))
                   collect (list :index (etaf-weread--required-number
                                         (plist-get chapter :chapterIdx))
                                 :title (or (etaf-weread--string (plist-get chapter :title))
                                            "—")
                                 :words (etaf-weread--required-number
                                         (plist-get chapter :wordCount))
                                 :paid (etaf-weread--truthy-p (plist-get chapter :paid)))))))

(defun etaf-weread--notes-from-data (data id)
  "Return the highlights plist built from backend DATA for book ID.
Highlights keep their backend order and are grouped by chapter; a thought is
attached to the highlight carrying the same range, and thoughts without a
matching highlight collect under 其他想法."
  (let* ((payload (etaf-weread--payload data))
         (book (plist-get payload :book))
         (highlights (etaf-weread--list (plist-get payload :highlights)))
         (reviews (etaf-weread--list (plist-get payload :reviews)))
         (leftover (copy-sequence reviews))
         (groups nil))
    (dolist (highlight highlights)
      (let* ((chapter (or (etaf-weread--string (plist-get highlight :chapterName))
                          "未分章"))
             (range (etaf-weread--string (plist-get highlight :range)))
             (thought (seq-find (lambda (review)
                                  (equal (etaf-weread--string (plist-get review :range))
                                         range))
                                leftover))
             (group (cl-find chapter groups
                             :key (lambda (item) (plist-get item :chapter))
                             :test #'equal)))
        (when thought
          (setq leftover (delq thought leftover)))
        (unless group
          (setq group (list :chapter chapter :items nil))
          (setq groups (append groups (list group))))
        (let* ((bookmark (etaf-weread--string (plist-get highlight :bookmarkId)))
               (row-id (if (string-empty-p bookmark)
                           (format "hl:%s:%s" id range)
                         bookmark))
               (item (list :id row-id
                           :text (etaf-weread--string (plist-get highlight :markText))
                           :thought (and thought
                                         (etaf-weread--string (plist-get thought :content)))
                           :time (etaf-weread--required-number
                                  (plist-get highlight :createTime)))))
          (plist-put group :items
                     (append (plist-get group :items) (list item))))))
    (when leftover
      (let ((items nil))
        (cl-loop for review in leftover
                 for position from 0
                 do (let* ((review-id (etaf-weread--string
                                       (plist-get review :reviewId)))
                           (row-id (if (string-empty-p review-id)
                                       (format "review:%s:%d" id position)
                                     (format "review:%s" review-id))))
                      (setq items
                            (append items
                                    (list (list :id row-id
                                                :text ""
                                                :thought (etaf-weread--string
                                                          (plist-get review :content))
                                                :time (etaf-weread--required-number
                                                       (plist-get review :createTime))))))))
        (setq groups (append groups
                             (list (list :chapter "其他想法" :items items))))))
    (list :id id
          :title (or (etaf-weread--string (plist-get book :title)) id)
          :count (+ (length highlights) (length reviews))
          :highlights (length highlights)
          :thoughts (length reviews)
          :groups groups)))

(defun etaf-weread--stats-from-data (data)
  "Return the reading statistics built from backend DATA.
The summary counts are top-level fields; the title lists live in the reply's
`data' object."
  (let ((payload (etaf-weread--payload data)))
    (list :books (etaf-weread--required-number (plist-get data :books))
          :finished (etaf-weread--required-number (plist-get data :finished))
          :reading (etaf-weread--required-number (plist-get data :reading))
          :notes (etaf-weread--required-number (plist-get data :notes))
          :total-seconds (etaf-weread--required-number
                          (plist-get data :total_reading_seconds))
          :total-time (etaf-weread--string (plist-get data :total_reading_time))
          :conclusion (etaf-weread--string (plist-get data :conclusion))
          :finished-books (mapcar (lambda (title)
                                    (etaf-weread--string title))
                                  (etaf-weread--list (plist-get payload :finished)))
          :reading-books (cl-loop for item in (etaf-weread--list (plist-get payload :reading))
                                  collect (list :title (etaf-weread--string
                                                        (plist-get item :title))
                                                :progress (etaf-weread--required-number
                                                           (plist-get item :progress)))))))

;;; ---------------------------------------------------------------------------
;;; Selection, panes and actions
;;; ---------------------------------------------------------------------------

(defun etaf-weread-move-selection (app delta)
  "Move APP's list selection by DELTA rows and keep it inside the page.
While the detail pane is visible the pane follows the settled selection."
  (let* ((rows (etaf-weread--read app :rows))
         (total (length rows))
         (size (max 1 (etaf-weread--read app :page-size))))
    (when (> total 0)
      (let ((previous (etaf-weread--read app :selection))
            (selection (max 0 (min (1- total)
                                   (+ (etaf-weread--read app :selection) delta))))
            (start (etaf-weread--read app :window-start)))
        (cond ((< selection start) (setq start selection))
              ((>= selection (+ start size)) (setq start (- (1+ selection) size))))
        (etaf-weread--write app :selection selection)
        (etaf-weread--write app :window-start (max 0 start))
        (when (and (/= selection previous)
                   (etaf-weread--pane-shown-p app))
          (etaf-weread--schedule-detail app (etaf-weread--selected-id app)))))))

(defun etaf-weread-activate-selection (app)
  "Open the book APP's selection points at.
In the notebook section the highlight pane opens; elsewhere the detail pane
opens.  An indexed highlight row opens the highlights of its book.  An empty
list does nothing."
  (when-let* ((row (etaf-weread--selected-row app)))
    (if (plist-get row :local)
        (etaf-weread-open-local-book app (plist-get row :id))
      (if (eq (plist-get row :kind) :highlight)
          (etaf-weread-show-book app (plist-get row :book) 'notes)
        (let ((pane (if (eq (plist-get (etaf-weread-state app) :section) :notebook)
                        'notes
                      'detail)))
          (etaf-weread-show-book app row pane))))))

(defun etaf-weread-press-row (app index)
  "Press list row INDEX (counting from 1) in APP.
Pressing another row selects it; pressing the selected row again opens it.
This is the gesture a click on a list row performs, which a programmatic
caller can use to follow the same sentence.  An out-of-range INDEX signals
`etaf-weread-error'."
  (let ((total (length (etaf-weread--read app :rows))))
    (unless (and (integerp index) (>= index 1) (<= index total))
      (signal 'etaf-weread-error (list (format "No row %S" index))))
    (if (= (1- index) (etaf-weread--read app :selection))
        (etaf-weread-activate-selection app)
      (etaf-weread--write app :selection (1- index))
      (etaf-weread--clamp-list-position app)
      (when (etaf-weread--pane-shown-p app)
        (etaf-weread--schedule-detail app (etaf-weread--selected-id app))))))

(defun etaf-weread-show-pane (app pane)
  "Show PANE in APP and return it.
PANE is `detail' for the book card with its table of contents, or `notes' for
the highlights and thoughts.  A `wide' layout keeps every column visible, so
there PANE is remembered without removing anything; compact layouts show that
single pane.  Opening the notes loads them when they are not cached yet."
  (unless (memq pane '(detail notes))
    (signal 'etaf-weread-error (list (format "Unknown pane: %S" pane))))
  (etaf-weread--write app :pane pane)
  (etaf-weread--write app :pane-scroll 0)
  (when (and (eq pane 'notes)
             (etaf-weread--detail-id app)
             (not (gethash (etaf-weread--detail-id app)
                           (plist-get app :notes-cache))))
    (etaf-weread--load-notes app (etaf-weread--detail-id app)))
  pane)

(defun etaf-weread-toggle-pane (app)
  "Switch APP's side pane between the book detail and its highlights."
  (etaf-weread-show-pane app
                         (if (eq (etaf-weread--effective-pane app) 'detail)
                             'notes
                           'detail)))

(defun etaf-weread--pane-page-rows (app)
  "Return how many rows one page of APP's side pane holds.
The reading pane shows one row per line per column, so a two-column spread
advances twice as far as a single column when paging."
  (let ((rows (if (eq (etaf-weread--effective-pane app) 'reader)
                  (max 1 (etaf-weread--read app :reader-rows))
                (max 1 (etaf-weread--read app :pane-rows)))))
    (if (eq (etaf-weread--effective-pane app) 'reader)
        (* rows (max 1 (etaf-weread--read app :reader-shown)))
      rows)))

(defun etaf-weread--update-reader-progress (app)
  "Publish how far APP is through its open local book, in percent.
The reading head shows it, and it counts the chapter's own position, so
scrolling inside one chapter moves the number as a reader expects."
  (let* ((local (etaf-weread--read app :local))
         (chapters (length (plist-get local :chapters)))
         (index (or (plist-get local :index) 0))
         (rows (max 1 (etaf-weread--read app :pane-rows)))
         (total (max 1 (etaf-weread--read app :pane-total)))
         (scroll (etaf-weread--read app :pane-scroll))
         (through (if (<= total rows) 1.0 (/ (float (+ scroll rows)) total)))
         (progress (if (zerop chapters)
                       0
                     (round (* 100 (/ (+ index (min 1.0 through)) chapters))))))
    (etaf-weread--write app :reader-progress (min 100 progress))))

(defun etaf-weread-scroll-pane (app delta)
  "Scroll APP's reading, detail or highlight pane by DELTA rows."
  (let* ((total (etaf-weread--read app :pane-total))
         (size (etaf-weread--pane-page-rows app)))
    (etaf-weread--write app :pane-scroll
                        (max 0 (min (+ (etaf-weread--read app :pane-scroll) delta)
                                    (max 0 (- total size)))))
    (when (eq (etaf-weread--effective-pane app) 'reader)
      (etaf-weread--update-reader-progress app)
      (etaf-weread--schedule-position-save app))))

(defun etaf-weread-reader-url (item)
  "Return the WeChat Reading URL of ITEM, or nil.
ITEM is a book row or a book id.  The backend's deep link is used when it has
one, otherwise the id addresses the web reader."
  (let ((deep-link (and (listp item) (etaf-weread--string (plist-get item :deep-link))))
        (id (etaf-weread--item-id item)))
    (cond ((and deep-link (not (string-empty-p deep-link))) deep-link)
          ((and (stringp item) (string-match-p "\\`https?://" item)) item)
          ((and id (not (string-empty-p id)))
           (format "https://weread.qq.com/web/reader/%s" id))
          (t nil))))

(defun etaf-weread-open-book (app &optional item)
  "Open ITEM, or APP's selected book, in the WeChat Reading web reader.
The browser is opened through `browse-url', so the reader keeps running while
the account reads.  A book without a URL signals `etaf-weread-error'."
  (let* ((item (or item (etaf-weread--selected-row app)))
         (url (etaf-weread-reader-url item)))
    (unless url
      (signal 'etaf-weread-error '("No book to open")))
    (etaf-weread--note app (format "在浏览器中打开：%s"
                                   (or (etaf-weread--item-title item) url)))
    (browse-url url)
    url))

(defun etaf-weread-export-notes (app &optional item)
  "Export the highlights and thoughts of ITEM, or the selected book, as Markdown.
The skill writes the file under its configured export directory and the reply
is reported in the status line.  A book without an id signals
`etaf-weread-error'."
  (let* ((item (or item (etaf-weread--selected-row app)))
         (id (etaf-weread--item-id item)))
    (unless id
      (signal 'etaf-weread-error '("No book to export")))
    (etaf-weread--note app (format "正在导出笔记：%s…"
                                   (or (etaf-weread--item-title item) id)))
    (etaf-weread--call
     app (list :op :export :id id)
     :on-ok (lambda (data)
              (etaf-weread--note app
                                 (or (etaf-weread--string (plist-get data :conclusion))
                                     (format "笔记已导出：%s" id)))))
    id))

(defun etaf-weread-refresh (app)
  "Reload APP's current list, account and statistics.
The list reload keeps the reader's position and re-fits the layout to the
window that shows APP."
  (etaf-weread--write app :error nil)
  (etaf-weread--sync-layout app)
  (let* ((section (etaf-weread--read app :section))
         (key (etaf-weread--list-key app section)))
    (setf (plist-get app :list-key) key)
    (etaf-weread--load-list app key (etaf-weread--list-request app section) t)
    (when (eq section :search)
      (etaf-weread--write app :query (etaf-weread--read app :query))))
  (etaf-weread--request-account app)
  ;; The statistics summary is cheap and feeds the status line, so a mounted
  ;; reader keeps it warm even while browsing another section.
  (unless (eq (etaf-weread--read app :section) :stats)
    (etaf-weread--request-stats app))
  (when (eq (etaf-weread--read app :section) :stats)
    (etaf-weread--request-stats app))
  (when (eq (etaf-weread--read app :section) :index)
    (etaf-weread--index-reload app))
  (etaf-weread--sync-pane-total app))

(defun etaf-weread--request-account (app)
  "Load APP's account from the stored login."
  (etaf-weread--call
   app (list :op :status)
   :on-ok (lambda (data)
            (etaf-weread--write app :account
                                (list :name (or (etaf-weread--string
                                                 (plist-get data :name))
                                                "已登录")
                                      :vid (etaf-weread--string (plist-get data :vid))
                                      :login (etaf-weread--string (plist-get data :login))))
            (etaf-weread--write app :summary
                                (or (etaf-weread--read app :summary) "")))))

(defun etaf-weread--request-stats (app)
  "Load APP's aggregate reading statistics into the summary."
  (etaf-weread--call
   app (list :op :stats)
   :on-ok (lambda (data)
            (etaf-weread--write app :stats (etaf-weread--stats-from-data data))
            (unless (plist-get (etaf-weread--read app :stats) :error)
              (when (or (null (etaf-weread--read app :rows))
                        (eq (etaf-weread--read app :section) :stats))
                (etaf-weread--write app :summary
                                    (etaf-weread--string
                                     (plist-get data :conclusion))))))))

;;; ---------------------------------------------------------------------------
;;; Local highlight index
;;; ---------------------------------------------------------------------------

(defun etaf-weread--index-reload (app)
  "Show APP's local highlight index filtered by its `:index-query'.
The rows are read from the SQLite index through ETAF DB; a storage failure is
reported in the status line instead of breaking the reader."
  (condition-case error
      (let* ((stored (etaf-weread--index-rows app))
             (query (etaf-weread--read app :index-query))
             (rows (etaf-weread--index-list-rows
                    (etaf-weread--index-sorted
                     (etaf-weread--index-filter stored query)))))
        (etaf-batch
          (etaf-weread--write app :rows rows)
          (etaf-weread--write app :list-total (length rows))
          (etaf-weread--clamp-list-position app)
          (etaf-weread--write app :loading nil)
          (etaf-weread--write app :summary
                              (format "本地索引 %d 条%s"
                                      (length rows)
                                      (if (string-empty-p (string-trim query))
                                          ""
                                        (format "（筛选：%s）" (string-trim query)))))
          (etaf-weread--note
           app (if (and (string-empty-p (string-trim query)) (null rows))
                   "本地索引还是空的：按 I 索引笔记本，或先翻几本书的笔记"
                 (format "本地索引 %d 条" (length rows)))))
        (length rows))
    (error
     (etaf-weread--write app :rows nil)
     (etaf-weread--write app :list-total 0)
     (etaf-weread--write app :loading nil)
     (etaf-weread--write app :error (error-message-string error))
     (etaf-weread--note app (format "本地索引不可用：%s" (error-message-string error)))
     0)))

(defun etaf-weread-index-search (app &optional keyword)
  "Filter APP's local highlight index by KEYWORD and show the results.
KEYWORD matches the highlight, the thought, the chapter and the book title
case-insensitively; nil or an empty keyword shows every indexed highlight.
The `:index' section is shown, which is also what `etaf-weread-locate' does."
  (etaf-weread--write app :index-query (or keyword ""))
  (etaf-weread-locate app :index)
  (length (etaf-weread--read app :rows)))

(defun etaf-weread-index-notebook (app &optional refresh)
  "Index the highlights of every notebook book into APP's SQLite index.
The notebook is listed once; the books not indexed yet are fetched one at a
time in the background, and REFRESH non-nil re-fetches books that are already
indexed.  Progress is reported in the status line and a reply after dispose is
dropped.  Return the generation of this run."
  (let ((generation (cl-incf (plist-get app :index-generation))))
    (setf (plist-get app :index-pending) nil)
    (etaf-weread--write app :index-syncing "正在读取笔记本…")
    (etaf-weread--note app "正在读取笔记本…")
    (etaf-weread--call
     app (list :op :notebook :limit etaf-weread-list-limit)
     :on-ok (lambda (data)
              (when (= generation (plist-get app :index-generation))
                (let* ((payload (etaf-weread--payload data))
                       (books (etaf-weread--book-rows (plist-get payload :books) :notebook))
                       (indexed (and (not refresh) (etaf-weread--index-books app)))
                       (pending (cl-remove-if
                                 (lambda (row)
                                   (and indexed (gethash (plist-get row :id) indexed)))
                                 books)))
                  (setf (plist-get app :index-pending)
                        (list :generation generation :remaining pending
                              :total (length pending) :done 0
                              :stored 0))
                  (if pending
                      (progn
                        (etaf-weread--write app :index-syncing
                                            (format "索引 0/%d" (length pending)))
                        (etaf-weread--index-step app))
                    (progn
                      (etaf-weread--write app :index-syncing nil)
                      (etaf-weread--note app "索引已是最新")
                      (when (eq (etaf-weread--read app :section) :index)
                        (etaf-weread--index-reload app)))))))
     :on-error (lambda (_message _hint _code)
                 (when (= generation (plist-get app :index-generation))
                   (etaf-weread--write app :index-syncing nil))))
    generation))

(defun etaf-weread--index-step (app)
  "Fetch the next pending notebook book and store its highlights.
Every reply checks the run generation, so a disposed session or a newer index
run never continues an older walk.  One book is in flight at a time, which
keeps the skill's rate limit and the progress line honest."
  (let* ((pending (plist-get app :index-pending))
         (generation (and pending (plist-get pending :generation))))
    (when (and pending (= generation (plist-get app :index-generation)))
      (if (null (plist-get pending :remaining))
          (progn
            (setf (plist-get app :index-pending) nil)
            (etaf-weread--write app :index-syncing nil)
            (etaf-weread--note app
                               (format "索引完成：写入 %d 条"
                                       (plist-get pending :stored)))
            (when (eq (etaf-weread--read app :section) :index)
              (etaf-weread--index-reload app)))
        (let* ((remaining (plist-get pending :remaining))
               (row (car remaining))
               (id (plist-get row :id))
               (title (or (plist-get row :title) id)))
          (etaf-weread--write app :index-syncing
                              (format "索引 %d/%d：%s"
                                      (1+ (plist-get pending :done))
                                      (plist-get pending :total)
                                      (truncate-string-to-width title 16 nil nil "…")))
          (etaf-weread--call
           app (list :op :notes :id id)
           :on-ok (lambda (data)
                    (when (= generation (plist-get app :index-generation))
                      (condition-case error
                          (let ((counts (etaf-weread--index-store
                                         app id (etaf-weread--notes-from-data data id))))
                            (plist-put pending :stored
                                       (+ (plist-get pending :stored)
                                          (plist-get counts :stored))))
                        (error
                         (etaf-weread--note app
                                            (format "索引写入失败：%s"
                                                    (error-message-string error)))))
                      (plist-put pending :remaining (cdr remaining))
                      (plist-put pending :done (1+ (plist-get pending :done)))
                      (etaf-weread--index-step app)))
           :on-error (lambda (message _hint _code)
                       (when (= generation (plist-get app :index-generation))
                         (setf (plist-get app :index-pending) nil)
                         (etaf-weread--write app :index-syncing nil)
                         (etaf-weread--note app (format "索引中断：%s" message))))))))))

;;; ---------------------------------------------------------------------------
;;; Layout fitting
;;; ---------------------------------------------------------------------------

(defun etaf-weread--page-size-for (window &optional layout)
  "Return the book row count that fits WINDOW's height in LAYOUT.
Compact layouts spend lines on the chip strip and pane tabs, so they fit fewer
rows than the wide three-column layout."
  (let* ((height (if (and window (window-live-p window))
                     (window-body-height window)
                   (frame-height)))
         ;; The chrome includes the root's top padding line.
         (chrome (pcase layout
                   ('narrow 16)
                   ('medium 14)
                   (_ 11))))
    (max 1 (- height chrome))))

(defun etaf-weread--pane-rows-for (window layout)
  "Return the content rows of the side pane fitting WINDOW in LAYOUT.
The book card above the chapter list takes about ten lines; the notes pane has
a shorter heading.  A compact layout gives the pane the full body height."
  (let* ((height (if (and window (window-live-p window))
                     (window-body-height window)
                   (frame-height)))
         ;; The chrome includes the root's top padding line.
         (chrome (pcase layout
                   ('narrow 16)
                   ('medium 14)
                   (_ 15))))
    (max 1 (- height chrome))))

(defun etaf-weread--reader-font-scale (font)
  "Return the size ratio of the reading FONT preset.
An unknown FONT counts as `medium', so a stored preference from a newer
version never breaks a session."
  (or (cdr (assq (or font 'medium) etaf-weread--reader-font-scales))
      (cdr (assq 'medium etaf-weread--reader-font-scales))))

(defun etaf-weread--font-face (pixels)
  "Return the face Ebox resolves for text of PIXELS CSS reference pixels.
The projection is the engine's own: CSS pixels convert to integer decipoints,
and the face carries only the size so the family stays the user's."
  (list :height (floor (+ (* pixels 7.5) 0.5))))

(defun etaf-weread--font-info (face window &optional sample)
  "Return SAMPLE's `font-info' metrics under FACE in WINDOW, or nil.
The reader asks the same question the Ebox font projection asks before it
paints a text row, so the page budget counts the height that is really used.
SAMPLE defaults to Latin text; a Chinese book needs its CJK fallback probed
as well because that font's descent is what makes the row taller."
  (let* ((probe (propertize (or sample "M ") 'face (or face 'default)))
         (font (ignore-errors (font-at 0 window probe)))
         ;; The full XLFD name carries the resolved size; `font-get :name' does
         ;; not for a fallback font, and `font-info' would then report the
         ;; family's default size instead of the one the row is painted at.
         (name (and font (or (and (fboundp 'font-xlfd-name)
                                  (ignore-errors (font-xlfd-name font)))
                             (ignore-errors (font-get font :name)))))
         (frame (if (and window (window-live-p window))
                    (window-frame window)
                  (selected-frame))))
    (and name (ignore-errors (font-info name frame)))))

(defun etaf-weread--frame-line-pixels (window)
  "Return WINDOW's frame line height in pixels."
  (let ((frame (if (and window (window-live-p window))
                   (window-frame window)
                 (selected-frame))))
    (max 1 (frame-char-height frame))))

(defun etaf-weread--default-font-pixels (window)
  "Return the CSS reference pixel size of WINDOW's default font, or nil."
  (when-let* ((info (etaf-weread--font-info nil window)))
    (let ((size (aref info 2)))
      (and (numberp size) (> size 0) size))))

(defvar etaf-weread--font-pixels-cache (make-hash-table :test 'equal)
  "Resolved CSS pixel size of each reading font target, keyed by frame.
Fonts resolve to discrete sizes and a display scales CSS reference pixels
its own way, so a preset is resolved by measuring candidates once per frame.")

(defun etaf-weread--font-actual-pixels (pixels window)
  "Return the pixel size the font of CSS PIXELS resolves to in WINDOW, or nil."
  (when-let* ((info (etaf-weread--font-info (etaf-weread--font-face pixels) window)))
    (let ((size (aref info 2)))
      (and (numberp size) (> size 0) size))))

(defun etaf-weread--font-pixels-closest (target window)
  "Return the CSS pixel size whose font is closest to TARGET display pixels.
The engine converts CSS reference pixels to points before a font is resolved,
and a display defines how many pixels a point is, so the nominal size is not
the size that gets painted; the candidates are measured and the closest one
wins, which keeps small, medium and large apart on every font."
  (let* ((frame (if (and window (window-live-p window))
                    (window-frame window)
                  (selected-frame)))
         (key (list frame target))
         (missing (make-symbol "etaf-weread-font-missing"))
         (cached (gethash key etaf-weread--font-pixels-cache missing)))
    (if (not (eq cached missing))
        cached
      (let ((best nil) (best-distance nil))
        (dolist (candidate (number-sequence 6 (max 48 (round (* target 2)))))
          (when-let* ((actual (etaf-weread--font-actual-pixels candidate window)))
            (let ((distance (abs (- actual target))))
              (when (or (null best-distance)
                        (< distance best-distance)
                        (and (= distance best-distance) (< candidate best)))
                (setq best candidate best-distance distance)))))
        (when (> (hash-table-count etaf-weread--font-pixels-cache) 128)
          (clrhash etaf-weread--font-pixels-cache))
        (puthash key best etaf-weread--font-pixels-cache)
        best))))

(defun etaf-weread--reader-font-pixels (app window)
  "Return the CSS pixel size of APP's reading text, or nil for the frame font.
`medium' returns nil so the reader keeps the frame's own font untouched; the
other presets ask for a multiple of that font's pixel size and let the font
resolution pick the size that comes closest to it."
  (let ((scale (etaf-weread--reader-font-scale (etaf-weread--read app :reader-font))))
    (unless (= scale 1.0)
      (when-let* ((base (etaf-weread--default-font-pixels window)))
        (etaf-weread--font-pixels-closest (max 1 (round (* base scale))) window)))))

(defun etaf-weread--reader-font-width (app window)
  "Return the character width of APP's reading text in pixels."
  (let* ((pixels (etaf-weread--reader-font-pixels app window))
         (frame (if (and window (window-live-p window))
                    (window-frame window)
                  (selected-frame)))
         (fallback (max 1 (frame-char-width frame))))
    (or (and pixels
             (ignore-errors
               (string-pixel-width
                (propertize "0" 'face (etaf-weread--font-face pixels)))))
        fallback)))

(defun etaf-weread--font-line-pixels (pixels window)
  "Return the pixel line height of the font of CSS PIXELS in WINDOW.
A line is as tall as the tallest ascent plus the tallest descent of every
font its text uses, and a Chinese book mixes the frame's Latin font with a
CJK fallback; probing both keeps the row budget from cutting a line."
  (let* ((face (etaf-weread--font-face pixels))
         (probes (delq nil (list (etaf-weread--font-info face window "M ")
                                 (etaf-weread--font-info face window "汉。")))))
    (when probes
      (+ (apply #'max (mapcar (lambda (info) (or (aref info 8) 0)) probes))
         (apply #'max (mapcar (lambda (info) (or (aref info 9) 0)) probes))))))

(defun etaf-weread--reader-row-pixels (app window)
  "Return the pixel pitch of APP's reading rows in WINDOW.
`medium' keeps the frame's own line height, and so does every preset while
no chapter is on screen: the canvas only has to shrink while scaled rows are
really painted.  A scaled preset reads the height of the font it will paint,
and the frame's own line height is a floor, because a blank line and a
frame-font neighbour stay at least that tall.  A frame that cannot resolve
fonts (a terminal or a batch run) estimates from the ratio."
  (let* ((scale (etaf-weread--reader-font-scale (etaf-weread--read app :reader-font)))
         (char-h (etaf-weread--frame-line-pixels window)))
    (if (or (= scale 1.0)
            (not (eq (etaf-weread--effective-pane app) 'reader)))
        char-h
      (let* ((pixels (etaf-weread--reader-font-pixels app window))
             (text (or (and pixels (etaf-weread--font-line-pixels pixels window))
                       (max 1 (round (* char-h scale))))))
        (max char-h text)))))

(defun etaf-weread--reader-canvas-lines (window row-height)
  "Return how many canvas lines WINDOW holds for ROW-HEIGHT pixel rows.
The renderer plans its canvas in lines of the frame's own height, while a
scaled reading font paints taller rows; the mount and every refit hand it
this count, so the painted canvas stays inside the window instead of growing
past it.  `medium' has ROW-HEIGHT equal to the frame line height, and then
this is exactly the window's body height."
  (let* ((char-h (etaf-weread--frame-line-pixels window))
         (pixels (if (and window (window-live-p window))
                     (* (window-body-height window) char-h)
                   (* (frame-height) char-h))))
    (max 4 (floor pixels (float (max 1 row-height))))))

(defun etaf-weread--reader-rows-for (window layout zen row-height)
  "Return how many text rows one reading column holds in WINDOW.
The reading view spends rows on its top padding, the running head and a blank
separator, plus the footer and the frame's own bottom padding, and one row
stays free below the text; a zen frame hides the head and the separator.  The
canvas holds `etaf-weread--reader-canvas-lines' rows of ROW-HEIGHT pixels, so
a larger reading font shows fewer of them and never paints past the window."
  (let ((lines (etaf-weread--reader-canvas-lines window row-height))
        (outside (if zen 2 (if (eq layout 'wide) 3 4)))
        (inside (if zen 1 3)))
    (max 3 (- lines outside inside))))

(defun etaf-weread--window-columns (&optional window)
  "Return WINDOW's body width in columns, or the frame width when it is dead."
  (if (and window (window-live-p window))
      (window-body-width window)
    (frame-width)))

(defun etaf-weread--reader-capacity-for (app window layout)
  "Return the columns the reading pane can give its text in WINDOW.
The count is in the reading font's own character width, so a larger preset
fits fewer columns in the same pane and a wrapped line still stays inside its
column.  A zen frame keeps the whole body for the reader; otherwise the
section sidebar or rail keeps its own columns, and an inset keeps the text
clear of the pane's edge.  A frame too narrow for LAYOUT still returns a
readable floor."
  (let* ((frame (if (and window (window-live-p window))
                    (window-frame window)
                  (selected-frame)))
         (char-w (max 1 (frame-char-width frame)))
         (pixels (if (and window (window-live-p window))
                     (* (window-body-width window) char-w)
                   (* (frame-width frame) char-w)))
         (chrome (if (etaf-weread--read app :zen)
                     0
                   (if (eq layout 'wide)
                       etaf-weread--sidebar-columns
                     etaf-weread--rail-columns)))
         (unit (etaf-weread--reader-font-width app window)))
    (max etaf-weread--reading-min-columns
         (floor (- pixels (* (+ chrome 2) char-w)) (float unit)))))

(defun etaf-weread--reading-columns (app)
  "Return the wrap width of APP's reading column, in columns.
The preference is capped by what the pane can hold, so no line is clipped
when the frame is narrower than the chosen measure."
  (max etaf-weread--reading-min-columns
       (min (etaf-weread--read app :reader-measure)
            (or (etaf-weread--read app :reader-columns)
                etaf-weread-reading-measure))))

(defun etaf-weread--reader-fit (capacity columns)
  "Return how many COLUMNS-wide reading columns fit CAPACITY columns.
The gutter between columns is part of the pitch, and the result stays inside
one and `etaf-weread--reader-max-columns'."
  (let ((pitch (+ (max 1 columns) etaf-weread--reader-gutter)))
    (max 1 (min etaf-weread--reader-max-columns
                (/ (+ capacity etaf-weread--reader-gutter) pitch)))))

(defun etaf-weread--reader-shown (app capacity columns)
  "Return how many reading columns APP shows for CAPACITY and COLUMNS.
An automatic spread uses everything that fits; a pinned one never exceeds it."
  (let ((fit (etaf-weread--reader-fit capacity columns))
        (choice (etaf-weread--read app :reader-spread)))
    (if (integerp choice) (min choice fit) fit)))

(defun etaf-weread--rewrap-local-chapter (app)
  "Wrap APP's open local chapter again when the reading width changed.
The painted lines were wrapped for the old width, so without this they would
clip after a resize or a measure change."
  (when (and (plist-get (etaf-weread--read app :local) :chapters)
             (/= (etaf-weread--reading-columns app)
                 (or (etaf-weread--read app :reader-wrapped) 0)))
    (etaf-weread--publish-local-chapter app)))

(defun etaf-weread--viewport-options (app window)
  "Return mount viewport options for APP sized for WINDOW, or nil when dead.
The width follows the window.  The height is APP's canvas line count, which
shrinks with a scaled reading font so its taller rows do not paint past the
window."
  (when (and window (window-live-p window))
    (list :viewport-height (etaf-weread--read app :reader-canvas))))

(defun etaf-weread--refit-canvas (app window)
  "Refit APP's mounted canvas after its row pitch changed.
Changing the reading font does not resize the window, so the framework never
refits the canvas; without this the canvas would keep its old line count and a
scaled font would paint past it.  The refit also runs after a real resize,
where it only confirms the framework's own count."
  (let* ((buffer (plist-get app :buffer))
         (runtime (and (buffer-live-p buffer)
                       (etaf-runtime-for-buffer buffer)))
         (canvas (etaf-weread--read app :reader-canvas)))
    (when (and window (window-live-p window)
               runtime (etaf-runtime-mounted-p runtime)
               (/= canvas (or (cdr (etaf-runtime-viewport runtime)) 0)))
      (etaf-runtime-refit runtime nil canvas))))

(defun etaf-weread--layout-for (columns)
  "Return the layout COLUMNS columns of text can hold.
The result is `wide', `medium' or `narrow'; see `etaf-weread-wide-columns' and
`etaf-weread-medium-columns'."
  (cond ((>= columns etaf-weread-wide-columns) 'wide)
        ((>= columns etaf-weread-medium-columns) 'medium)
        (t 'narrow)))

(defun etaf-weread--sync-layout (app &optional window)
  "Match APP's layout, pane visibility and row budgets to WINDOW.
WINDOW defaults to the window showing APP's buffer.  A headless session keeps
the wide layout, because it has no viewport to adapt to.  The reading column
is refitted as well, and an open chapter is wrapped again when its width
changes."
  (let* ((buffer (plist-get app :buffer))
         (window (or window
                     (and (buffer-live-p buffer) (get-buffer-window buffer t))))
         (layout (if window
                     (etaf-weread--layout-for (etaf-weread--window-columns window))
                   'wide))
         (size (etaf-weread--page-size-for window layout))
         (font-pixels (etaf-weread--reader-font-pixels app window))
         (row-height (etaf-weread--reader-row-pixels app window))
         (canvas (etaf-weread--reader-canvas-lines window row-height))
         (capacity (etaf-weread--reader-capacity-for app window layout))
         (columns (min (etaf-weread--read app :reader-measure) capacity))
         (shown (etaf-weread--reader-shown app capacity columns)))
    (etaf-batch
      (etaf-weread--write app :layout layout)
      (etaf-weread--write app :page-size size)
      (etaf-weread--write app :window-rows
                          (if (and window (window-live-p window))
                              (window-body-height window)
                            (frame-height)))
      (etaf-weread--write app :pane-rows (etaf-weread--pane-rows-for window layout))
      (etaf-weread--write app :reader-font-size font-pixels)
      (etaf-weread--write app :reader-line-height row-height)
      (etaf-weread--write app :reader-canvas canvas)
      (etaf-weread--write app :reader-rows
                          (etaf-weread--reader-rows-for
                           window layout (etaf-weread--read app :zen)
                           row-height))
      (etaf-weread--write app :reader-capacity capacity)
      (etaf-weread--write app :reader-columns columns)
      (etaf-weread--write app :reader-shown shown)
      (etaf-weread--clamp-list-position app)
      (etaf-weread--sync-pane-total app))
    (etaf-weread--rewrap-local-chapter app)
    (etaf-weread--refit-canvas app window)
    layout))

(defun etaf-weread--compact-layout-p (app)
  "Return non-nil when APP shows one pane at a time."
  (not (eq (etaf-weread--read app :layout) 'wide)))

(defun etaf-weread--show-list-pane (app)
  "Bring APP's list pane back into view on a compact layout.
Loading a section, a filter or a store search is a list operation, and a
compact frame shows one pane at a time; it must leave the side pane it was
showing.  A wide layout keeps every column, so its pane choice is kept."
  (when (and (etaf-weread--compact-layout-p app)
             (not (eq (etaf-weread--read app :pane) 'list)))
    (etaf-weread--write app :pane 'list)
    ;; Leaving the reading pane stops the reading clock and gives the frame
    ;; its full canvas back when a scaled reading font had shrunk it.
    (etaf-weread--reading-pause app)
    (etaf-weread--sync-layout app)))

(defun etaf-weread--effective-pane (app)
  "Return the pane APP is actually showing.
A `wide' layout keeps the side pane visible, so a `list' reading there means
the detail pane; a compact layout shows exactly the recorded pane."
  (let ((pane (etaf-weread--read app :pane)))
    (if (and (eq pane 'list) (not (etaf-weread--compact-layout-p app)))
        'detail
      pane)))

(defun etaf-weread--list-shown-p (app)
  "Return non-nil when APP's book list fits in the frame.
The reading pane owns the frame's body while a local chapter is open, in every
layout, so the list steps aside for it."
  (and (not (eq (etaf-weread--read app :pane) 'reader))
       (or (not (etaf-weread--compact-layout-p app))
           (eq (etaf-weread--read app :pane) 'list))))

(defun etaf-weread--pane-shown-p (app)
  "Return non-nil when APP's reading, detail or highlight pane fits in the frame."
  (or (not (etaf-weread--compact-layout-p app))
      (memq (etaf-weread--read app :pane) '(reader detail notes))))

(defun etaf-weread--sync-pane-total (app)
  "Recompute the scrollable rows of APP's side pane."
  (let* ((total (pcase (etaf-weread--effective-pane app)
                  ('reader (length (etaf-weread--read app :reader-lines)))
                  ('notes (etaf-weread--notes-total app))
                  (_ (etaf-weread--detail-total app))))
         (page (etaf-weread--pane-page-rows app)))
    (etaf-weread--write app :pane-total total)
    (etaf-weread--write app :pane-scroll
                        (max 0 (min (etaf-weread--read app :pane-scroll)
                                    (max 0 (- total page)))))))
(defun etaf-weread--detail-total (app)
  "Return the scrollable chapter lines of APP's detail pane."
  (length (plist-get (etaf-value (etaf-weread--ref app :detail)) :chapters)))

(defun etaf-weread--notes-lines (groups)
  "Return GROUPS flattened into the lines of the highlight pane.
A chapter heading, a quote and a thought are each one line carrying `:kind';
this is what the pane counts and slices, so the pane's scroll budget and the
rendered lines always agree."
  (let ((lines nil)
        (position 0))
    (dolist (group groups)
      (push (list :key (cl-incf position)
                  :kind 'chapter
                  :text (or (plist-get group :chapter) ""))
            lines)
      (dolist (item (plist-get group :items))
        (let ((text (or (plist-get item :text) ""))
              (thought (or (plist-get item :thought) "")))
          (cl-incf position)
          (if (string-empty-p text)
              (unless (string-empty-p thought)
                (push (list :key position
                            :kind 'thought :text thought)
                      lines))
            (push (list :key position
                        :kind 'quote :text text :thought thought)
                  lines)))))
    (nreverse lines)))

(defun etaf-weread--notes-total (app)
  "Return the scrollable lines of APP's highlight pane."
  (length (etaf-weread--notes-lines
           (plist-get (etaf-value (etaf-weread--ref app :notes)) :groups))))

(defun etaf-weread--page-rows (app)
  "Return the visible slice of APP's rows as (ROWS START TOTAL)."
  (let* ((rows (etaf-weread--read app :rows))
         (total (length rows))
         (size (max 1 (etaf-weread--read app :page-size)))
         (start (max 0 (min (etaf-weread--read app :window-start)
                            (max 0 (- total size))))))
    (list (seq-subseq rows start (min total (+ start size))) start total)))

;;; ---------------------------------------------------------------------------
;;; Session lifecycle
;;; ---------------------------------------------------------------------------

(defvar etaf-weread--resize-timer nil
  "Pending trailing task that applies the latest window sizes.")

(defvar etaf-weread--resize-frames nil
  "Frames whose window sizes changed since the last applied batch.")

(defvar etaf-weread--resize-settle-delay 0.12
  "Seconds of quiet after the last resize event before applying a layout.
Applying the layout writes layout and page-size readings, and every write
republishes the whole view.  Dragging an edge fires far more events than one
publication costs, so apply once the drag settles instead of per event.")

(defun etaf-weread--window-size-change (frame)
  "Record FRAME's size change; apply it once the resize settles."
  (when (frame-live-p frame)
    (cl-pushnew frame etaf-weread--resize-frames)
    (when etaf-weread--resize-timer
      (cancel-timer etaf-weread--resize-timer))
    (setq etaf-weread--resize-timer
          (run-at-time etaf-weread--resize-settle-delay nil
                       #'etaf-weread--window-size-change-apply))))

(defun etaf-weread--transient-space-borrow-p (frame window app)
  "Whether FRAME's transient UI borrows WINDOW's lines from APP's layout.
An active minibuffer or completion popup takes lines from displayed windows
without the user resizing the frame; the reader keeps the layout it
committed, exactly as the canvas keeps its committed viewport.  Window
growth is real geometry and always applies.  A shorter window with no
transient UI above it is a real resize too."
  (let ((minibuffer (active-minibuffer-window)))
    (and minibuffer
         (eq (window-frame minibuffer) frame)
         (< (window-body-height window)
            (or (etaf-weread--read app :window-rows) 0)))))

(defun etaf-weread--window-size-change-apply ()
  "Adapt every mounted reader to its window's settled size.
The canvas refit itself is the framework's job: ETAF refits every mounted
runtime once a resize settles.  This only recomputes the reader layout, page
size and pane budgets that belong to the application.  A window whose lines
an active minibuffer borrows keeps the layout the reader already committed
until that UI releases them."
  (setq etaf-weread--resize-timer nil)
  (let ((frames (prog1 (nreverse etaf-weread--resize-frames)
                  (setq etaf-weread--resize-frames nil))))
    (dolist (frame frames)
      (when (frame-live-p frame)
        (dolist (window (window-list frame 'no-minibuf))
          (let ((buffer (window-buffer window)))
            (when (and (buffer-live-p buffer)
                       (buffer-local-value 'etaf-weread--model buffer))
              (let ((model (buffer-local-value 'etaf-weread--model buffer)))
                (unless (etaf-weread--transient-space-borrow-p frame window model)
                  (etaf-weread--sync-layout model window))))))))))

(defun etaf-weread--start (app)
  "Start APP: fit the layout, follow window resizes and warm the list cache.
Lists are cached per section and shown at once; a slow background timer
compares them with fresh replies and repaints only what changed, so the
sidebar stays current without ever making the reader wait."
  (setf (plist-get app :disposed) nil
        (plist-get app :started-at) (float-time))
  (etaf-weread--sync-layout app)
  (etaf-weread--schedule-prefetch app)
  (add-hook 'window-size-change-functions #'etaf-weread--window-size-change))

(defun etaf-weread--dispose (app)
  "Release APP's timers, local index and in-flight requests.
A position still waiting to be stored is written first, so closing the reader
keeps the place even when the scroll had not settled yet."
  (when-let* ((timer (plist-get app :position-timer)))
    (cancel-timer timer)
    (setf (plist-get app :position-timer) nil)
    (etaf-weread--remember-position app))
  (etaf-weread--reading-pause app)
  (etaf-weread--cancel-auto-scroll app)
  (setf (plist-get app :disposed) t)
  (cl-incf (plist-get app :index-generation))
  (setf (plist-get app :index-pending) nil)
  (when-let* ((timer (plist-get app :follow-timer)))
    (cancel-timer timer)
    (setf (plist-get app :follow-timer) nil))
  (etaf-list-cache-disarm (plist-get app :list-cache))
  (etaf-weread--index-dispose app)
  (etaf-weread-cancel (etaf-weread--client app)))

;;; ---------------------------------------------------------------------------
;;; Detached state for callers and tests
;;; ---------------------------------------------------------------------------

(defun etaf-weread-state (app)
  "Return APP's session state as a detached plist.
The snapshot is a copy: mutating it never changes the reader.  Keys are
`:section', `:filter', `:title', `:subtitle', `:mode', `:query', `:items'
(the loaded rows), `:visible' (the rows on the current page), `:selection',
`:window-start', `:page-size', `:rows-total' (loaded count), `:list-total'
(backend total or the loaded count), `:layout', `:pane', `:pane-rows',
`:pane-scroll', `:pane-total', `:detail', `:local', `:reader-lines' (the
wrapped text of the open local chapter), `:reader-title', `:reader-measure'
(the chosen reading column width in columns), `:reader-font' (the chosen
reading font preset), `:reader-font-size' (its CSS pixel size, nil for the
frame's own font), `:reader-line-height' (one reading row in pixels),
`:reader-columns' (the width the open chapter is wrapped to), `:zen' (whether
the reading-only layout is on), `:auto-scroll' (whether the reader advances
by itself), `:local-bindings' (the open local book's account binding and the
account progress of every bound local book), `:local-notes' (the account's
highlights matched to the open local book), `:notes', `:stats', `:account',
`:summary', `:theme', `:loading', `:error', `:message' and `:viewport-width'
(the pixel canvas the reader paints)."
  (let* ((rows (etaf-weread--read app :rows))
         (page (etaf-weread--page-rows app))
         (detail (etaf-weread--read app :detail))
         (notes (etaf-weread--read app :notes))
         (stats (etaf-weread--read app :stats)))
    (list :section (etaf-weread--read app :section)
          :filter (etaf-weread--read app :filter)
          :title (etaf-weread--read app :title)
          :subtitle (etaf-weread--read app :subtitle)
          :mode (etaf-weread--read app :mode)
          :query (etaf-weread--read app :query)
          :items (mapcar #'copy-sequence rows)
          :visible (mapcar #'copy-sequence (nth 0 page))
          :window-start (nth 1 page)
          :selection (etaf-weread--read app :selection)
          :page-size (etaf-weread--read app :page-size)
          :viewport-width
          (let ((runtime (and (buffer-live-p (plist-get app :buffer))
                              (etaf-runtime-for-buffer (plist-get app :buffer)))))
            (and runtime (etaf-runtime-mounted-p runtime)
                 (car (etaf-runtime-viewport runtime))))
          :rows-total (length rows)
          :list-total (etaf-weread--read app :list-total)
          :layout (etaf-weread--read app :layout)
          :pane (etaf-weread--read app :pane)
          :pane-rows (etaf-weread--read app :pane-rows)
          :pane-scroll (etaf-weread--read app :pane-scroll)
          :pane-total (etaf-weread--read app :pane-total)
          :detail (and detail (copy-sequence detail))
          :local (etaf-weread--read app :local)
          :local-bindings (let ((bindings (etaf-weread--read app :local-bindings)))
                            (and bindings (mapcar #'copy-sequence bindings)))
          :local-notes (let ((notes (etaf-weread--read app :local-notes)))
                         (and notes (copy-sequence notes)))
          :reader-lines (etaf-weread--read app :reader-lines)
          :reader-title (etaf-weread--read app :reader-title)
          :reader-measure (etaf-weread--read app :reader-measure)
          :reader-font (etaf-weread--read app :reader-font)
          :reader-font-size (etaf-weread--read app :reader-font-size)
          :reader-line-height (etaf-weread--read app :reader-line-height)
          :reader-columns (etaf-weread--read app :reader-columns)
          :reader-rows (etaf-weread--read app :reader-rows)
          :reader-spread (etaf-weread--read app :reader-spread)
          :reader-shown (etaf-weread--read app :reader-shown)
          :reader-capacity (etaf-weread--read app :reader-capacity)
          :reader-progress (etaf-weread--read app :reader-progress)
          :auto-scroll (etaf-weread--read app :auto-scroll)
          :bookmarks (let ((bookmarks (plist-get app :bookmarks)))
                       (and bookmarks (copy-sequence bookmarks)))
          :zen (etaf-weread--read app :zen)
          :notes (and notes (copy-sequence notes))
          :stats (and stats (copy-sequence stats))
          :account (let ((account (etaf-weread--read app :account)))
                     (and account (copy-sequence account)))
          :summary (etaf-weread--read app :summary)
          :index-query (etaf-weread--read app :index-query)
          :index-syncing (etaf-weread--read app :index-syncing)
          :theme (etaf-weread--read app :theme)
          :loading (etaf-weread--read app :loading)
          :error (etaf-weread--read app :error)
          :message (etaf-weread--read app :message))))

(provide 'etaf-weread-model)
;;; etaf-weread-model.el ends here
