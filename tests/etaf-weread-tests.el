;;; etaf-weread-tests.el --- Acceptance tests for etaf-weread -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public behaviour tests.  Every scenario drives the reader through the
;; interfaces declared in `etaf-weread.el' with a scripted client, so no test
;; needs the network, a login or a graphical frame.  The local index scenarios
;; exercise the real SQLite backend against a temporary database file.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-weread)

;;; ---------------------------------------------------------------------------
;;; Scripted backend
;;; ---------------------------------------------------------------------------

(defvar etaf-weread-tests--requests nil
  "Requests received by the scripted client, newest first.")

(defvar etaf-weread-tests--error nil
  "When non-nil, the scripted client fails every request with this message.")

(defvar etaf-weread-tests--thought "想法内容"
  "Thought the scripted client attaches to the matching highlight.")

(defvar etaf-weread-tests--book-count 2
  "Number of books the scripted shelf and notebook list.")

(defvar etaf-weread-tests--bindings nil
  "Local-book bindings the scripted client reports for `:bind'.
Each entry follows the skill's shape: `:file', `:book_id', `:title' and a
`:progress' plist with `:percent' and `:chapter_idx'.")

(defun etaf-weread-tests--books (&optional prefix)
  "Return BOOK-COUNT backend books named with PREFIX."
  (cl-loop for index from 1 to etaf-weread-tests--book-count
           collect (list :bookId (number-to-string index)
                         :title (format "%s书%d" (or prefix "") index)
                         :author (format "作者%d" index)
                         :progress (if (= index 1) 36 0)
                         :readingTime (if (= index 1) 4384 0))))

(defun etaf-weread-tests--notes (book-id title)
  "Return the notes reply of BOOK-ID named TITLE.
The second book carries an orphan thought, so grouping is observable."
  (list :ok t
        :data (list :book (list :bookId book-id :title title)
                    :highlights (list (list :bookmarkId (format "%s-b1" book-id)
                                            :chapterName "第一章" :range "1-2"
                                            :markText (format "%s的划线" title)
                                            :createTime 100))
                    :reviews (append
                              (list (list :reviewId (format "%s-r1" book-id)
                                          :range "1-2"
                                          :content etaf-weread-tests--thought
                                          :createTime 101))
                              (when (equal book-id "2")
                                (list (list :reviewId (format "%s-r2" book-id)
                                            :range "9-9"
                                            :content "没有划线的想法"
                                            :createTime 102)))))))

(defvar etaf-weread-tests--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this test file, resolved while it is loaded.")

(defvar etaf-weread-tests--extra-chapters nil
  "Extra chapters the scripted book reports, for tests that need a long pane.")

(defun etaf-weread-tests--client (request callback)
  "Answer REQUEST on CALLBACK from the scripted account."
  (push request etaf-weread-tests--requests)
  (if etaf-weread-tests--error
      (funcall callback (list :error etaf-weread-tests--error :hint "scripted"))
    (funcall callback
             (list :ok
                   (pcase (plist-get request :op)
                     (:status (list :ok t :login "ok" :name "测试读者" :vid "1"))
                     (:shelf (list :ok t :books etaf-weread-tests--book-count
                                   :reading 1 :finished 0
                                   :data (list :shelf (etaf-weread-tests--books))))
                     (:notebook (list :ok t :books etaf-weread-tests--book-count
                                      :notes 2 :reviews 2
                                      :data (list :books
                                                  (mapcar (lambda (book)
                                                            (list :bookId (plist-get book :bookId)
                                                                  :title (plist-get book :title)
                                                                  :counts (list :notes 1 :reviews 1)))
                                                          (etaf-weread-tests--books)))))
                     (:search (list :ok t
                                    :data (list :books
                                                (list (list :bookId "9" :title "搜到的书"
                                                            :author "作者" :rating 93)))))
                     (:book (list :ok t
                                  :data (list :book (list :bookId (plist-get request :id)
                                                          :title (format "详情节%s" (plist-get request :id))
                                                          :author "作者"
                                                          :category "文学"
                                                          :counts (list :notes 1 :reviews 1)
                                                          :intro "简介")
                                              :progress (list :progress 36 :readingTime 4384)
                                              :chapters (append
                                                         (list (list :chapterIdx 1 :title "第一章"
                                                                     :wordCount 100)
                                                               (list :chapterIdx 2 :title "第二章"
                                                                     :wordCount 200))
                                                         etaf-weread-tests--extra-chapters))))
                     (:notes (etaf-weread-tests--notes
                              (plist-get request :id)
                              (format "详情节%s" (plist-get request :id))))
                     (:stats (list :ok t :books etaf-weread-tests--book-count
                                   :finished 0 :reading 1 :notes 2
                                   :total_reading_seconds 4384
                                   :total_reading_time "1小时13分"
                                   :conclusion "读完 0 本 · 在读 1 本 · 累计 1小时13分"
                                   :data (list :top (etaf-weread-tests--books)
                                               :finished nil :reading nil)))
                     (:export (list :ok t :conclusion "已导出笔记"))
                     (:bind (list :ok t
                                  :data (list :bindings etaf-weread-tests--bindings)))
                     (:sync-progress
                      (list :ok t
                            :data (list :progress 5 :chapter_idx 1
                                        :chapter_offset 0 :synced t)))))))) 

(defvar etaf-weread-tests--settings nil
  "Settings file the next test session binds, for tests that share one file.")

(defun etaf-weread-tests--session (&optional client)
  "Return a reader session driven by the scripted CLIENT.
The session's preferences live in a disposable file, so a test never reads or
writes the settings file of a real reader.  A test that needs two sessions to
share one file binds `etaf-weread-tests--settings' first."
  (let ((etaf-weread-settings-file
         (or etaf-weread-tests--settings
             (make-temp-file "weread-tests-settings-" nil ".eld"))))
    (etaf-weread-create :client (or client #'etaf-weread-tests--client))))

(defun etaf-weread-tests--request (op)
  "Return the newest recorded request whose `:op' is OP."
  (seq-find (lambda (request) (eq (plist-get request :op) op))
            etaf-weread-tests--requests))

(defun etaf-weread-tests--request-count (op)
  "Return how many recorded requests use OP."
  (cl-count op etaf-weread-tests--requests :key (lambda (request)
                                                   (plist-get request :op))))

(defmacro etaf-weread-tests--with-index (&rest body)
  "Run BODY with a disposable SQLite index and index-on-read enabled."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "etaf-weread-index-" t))
          (etaf-weread-index-file (expand-file-name "notes.sqlite3" directory))
          (etaf-weread-index-on-read t))
     (unwind-protect
         (progn ,@body)
       (when (file-exists-p directory)
         (delete-directory directory t)))))

(defun etaf-weread-tests--wait (predicate &optional timeout)
  "Wait until PREDICATE is non-nil for at most TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

;;; ---------------------------------------------------------------------------
;;; Session and list behaviour
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-weread-tests-new-session-is-headless ()
  "A session built without a buffer sends no request and keeps its defaults."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (let ((state (etaf-weread-state app)))
      (should (eq (plist-get state :section) :shelf))
      (should (eq (plist-get state :pane) 'list))
      (should (eq (plist-get state :layout) 'wide))
      (should (equal (plist-get state :index-query) ""))
      (should (= (plist-get state :rows-total) 0)))
    (should-not etaf-weread-tests--requests)))

(ert-deftest etaf-weread-tests-refresh-loads-shelf-account-and-stats ()
  "Refreshing loads the shelf, the account and the reading statistics."
  (setq etaf-weread-tests--requests nil)
  (let* ((app (etaf-weread-tests--session))
         (state (progn (etaf-weread-refresh app) (etaf-weread-state app))))
    (should (= (plist-get state :rows-total) 2))
    (should (equal (plist-get (nth 0 (plist-get state :items)) :title) "书1"))
    (should (equal (plist-get (nth 0 (plist-get state :items)) :right) "1小时13分"))
    (should (string-match-p "书架 2 本" (plist-get state :message)))
    (should (equal (plist-get (plist-get state :account) :name) "测试读者"))
    (should (equal (plist-get (plist-get state :stats) :total-time) "1小时13分"))
    (should (memq :shelf (mapcar (lambda (request) (plist-get request :op))
                                 etaf-weread-tests--requests)))
    (should (= (plist-get state :list-total) 2))))

(ert-deftest etaf-weread-tests-sections-are-navigable ()
  "Every sidebar section opens and names itself; unknown sections signal."
  (etaf-weread-tests--with-index
    (setq etaf-weread-tests--requests nil)
    (let ((app (etaf-weread-tests--session)))
      (dolist (entry (apply #'append (mapcar #'cdr etaf-weread-sections)))
        (let ((section (car entry)))
          (etaf-weread-locate app section)
          (let ((state (etaf-weread-state app)))
            (should (eq (plist-get state :section) section))
            (should (equal (plist-get state :title) (nth 1 entry))))))
      (etaf-weread-locate app :shelf)
      (should-error (etaf-weread-locate app :nonsense) :type 'etaf-weread-error)
      (should (eq (plist-get (etaf-weread-state app) :section) :shelf)))))

(ert-deftest etaf-weread-tests-filter-selects-shelf-section ()
  "`etaf-weread-set-filter' shows the matching shelf section and filter."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (dolist (case '(("all" . :shelf) ("reading" . :reading) ("finished" . :finished)))
      (etaf-weread-set-filter app (car case))
      (should (eq (plist-get (etaf-weread-state app) :section) (cdr case))))
    (should (equal (plist-get (etaf-weread-tests--request :shelf) :filter) "finished"))
    (should-error (etaf-weread-set-filter app "sideways") :type 'etaf-weread-error)))

(ert-deftest etaf-weread-tests-search-trims-and-rejects-blank ()
  "Searching trims the keyword, shows the results, and rejects a blank one."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-search app "  三体  ")
    (let ((state (etaf-weread-state app)))
      (should (equal (plist-get state :query) "三体"))
      (should (eq (plist-get state :mode) 'search))
      (should (equal (plist-get (nth 0 (plist-get state :items)) :title) "搜到的书")))
    (should (equal (plist-get (etaf-weread-tests--request :search) :keyword) "三体"))
    (should-error (etaf-weread-search app "   ") :type 'etaf-weread-error)))

(ert-deftest etaf-weread-tests-selection-keeps-its-page ()
  "Selection clamps at both ends, scrolls the page, and activates a row."
  (setq etaf-weread-tests--requests nil)
  (let* ((etaf-weread-page-size 2)
         (app (etaf-weread-tests--session)))
    (etaf-weread-refresh app)
    (etaf-weread-move-selection app 5)
    (should (= (plist-get (etaf-weread-state app) :selection) 1))
    (etaf-weread-move-selection app -9)
    (should (= (plist-get (etaf-weread-state app) :selection) 0))
    (etaf-weread-activate-selection app)
    (should (eq (plist-get (etaf-weread-state app) :pane) 'detail))
    (should (equal (plist-get (plist-get (etaf-weread-state app) :detail) :id) "1"))))

;;; ---------------------------------------------------------------------------
;;; Book detail and highlights
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-weread-tests-show-book-loads-detail-and-chapters ()
  "Showing a book publishes its detail, chapters and counts from the cache."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-show-book app "7")
    (let ((detail (plist-get (etaf-weread-state app) :detail)))
      (should (equal (plist-get detail :id) "7"))
      (should (equal (plist-get detail :category) "文学"))
      (should (= (length (plist-get detail :chapters)) 2))
      (should (= (plist-get detail :progress) 36)))
    (should (= (etaf-weread-tests--request-count :book) 1))
    (etaf-weread-show-book app "7")
    (should (= (etaf-weread-tests--request-count :book) 1))))

(ert-deftest etaf-weread-tests-notes-group-and-attach-thoughts ()
  "Highlights group by chapter; a thought attaches and orphans collect apart."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-show-book app "2" 'notes)
    (let* ((notes (plist-get (etaf-weread-state app) :notes))
           (groups (plist-get notes :groups)))
      (should (= (plist-get notes :highlights) 1))
      (should (= (plist-get notes :thoughts) 2))
      (should (equal (plist-get (car groups) :chapter) "第一章"))
      (should (equal (plist-get (car (plist-get (car groups) :items)) :thought)
                     "想法内容"))
      (should (equal (plist-get (car (last groups)) :chapter) "其他想法"))
      (should (equal (plist-get (car (plist-get (car (last groups)) :items)) :text)
                     "")))))

(ert-deftest etaf-weread-tests-panes-toggle-and-load-notes ()
  "The side pane switches between detail and highlights and back."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-show-book app "2")
    (should (eq (plist-get (etaf-weread-state app) :pane) 'detail))
    (etaf-weread-toggle-pane app)
    (should (eq (plist-get (etaf-weread-state app) :pane) 'notes))
    (should (plist-get (etaf-weread-state app) :notes))
    (etaf-weread-toggle-pane app)
    (should (eq (plist-get (etaf-weread-state app) :pane) 'detail))
    (should-error (etaf-weread-show-pane app 'sideways) :type 'etaf-weread-error)
    (should (eq (plist-get (etaf-weread-state app) :pane) 'detail))))

(ert-deftest etaf-weread-tests-press-row-selects-then-opens ()
  "A press selects another row; pressing the selected row opens it."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-refresh app)
    (etaf-weread-press-row app 2)
    (should (= (plist-get (etaf-weread-state app) :selection) 1))
    (should-not (etaf-weread-tests--request :book))
    (etaf-weread-press-row app 2)
    (should (equal (plist-get (plist-get (etaf-weread-state app) :detail) :id) "2"))
    (should-error (etaf-weread-press-row app 99) :type 'etaf-weread-error)))

(ert-deftest etaf-weread-tests-reader-url-and-open-book ()
  "Reader URLs prefer the backend deep link and open through `browse-url'."
  (should (equal (etaf-weread-reader-url
                  '(:id "123" :deep-link "https://weread.qq.com/book-detail?x=1"))
                 "https://weread.qq.com/book-detail?x=1"))
  (should (equal (etaf-weread-reader-url "123")
                 "https://weread.qq.com/web/reader/123"))
  (should-not (etaf-weread-reader-url nil))
  (setq etaf-weread-tests--requests nil)
  (let* ((app (etaf-weread-tests--session))
         (opened nil))
    (etaf-weread-refresh app)
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url &rest _arguments) (setq opened url))))
      (etaf-weread-open-book app))
    (should (equal opened "https://weread.qq.com/web/reader/1"))))

(ert-deftest etaf-weread-tests-export-notes-sends-the-export-request ()
  "Exporting the selected book sends the skill export and reports its reply."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session)))
    (etaf-weread-refresh app)
    (etaf-weread-export-notes app)
    (should (equal (plist-get (etaf-weread-tests--request :export) :id) "1"))
    (should (equal (plist-get (etaf-weread-state app) :message) "已导出笔记"))))

;;; ---------------------------------------------------------------------------
;;; Local SQLite index
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-weread-tests-index-stores-and-searches-highlights ()
  "Reading highlights stores them in SQLite and the index section finds them."
  (etaf-weread-tests--with-index
    (setq etaf-weread-tests--requests nil)
    (let ((app (etaf-weread-tests--session)))
      (etaf-weread-show-book app "1" 'notes)
      (should (file-exists-p etaf-weread-index-file))
      (should (= (etaf-weread-index-search app "划线") 1))
      (should (equal (plist-get (etaf-weread-state app) :section) :index))
      (let ((row (car (plist-get (etaf-weread-state app) :items))))
        (should (eq (plist-get row :kind) :highlight))
        (should (equal (plist-get row :title) "详情节1")))
      ;; A non-matching keyword filters the index down to nothing.
      (should (= (etaf-weread-index-search app "不存在的词") 0))
      (should (= (etaf-weread-index-search app "") 1)))))

(ert-deftest etaf-weread-tests-index-notebook-walks-and-skips-indexed ()
  "The notebook walk fetches unindexed books once and skips them afterwards."
  (etaf-weread-tests--with-index
    (setq etaf-weread-tests--requests nil)
    (let ((app (etaf-weread-tests--session)))
      (etaf-weread-index-notebook app)
      (should (= (etaf-weread-tests--request-count :notes) 2))
      (should (string-match-p "索引完成：写入 3 条"
                              (or (plist-get (etaf-weread-state app) :message) "")))
      ;; Two highlights plus the orphan thought mention 划线.
      (should (= (etaf-weread-index-search app "划线") 3))
      (etaf-weread-index-notebook app)
      (should (= (etaf-weread-tests--request-count :notes) 2))
      (etaf-weread-index-notebook app t)
      (should (= (etaf-weread-tests--request-count :notes) 4))
      (should (= (etaf-weread-index-search app "划线") 3)))))

(ert-deftest etaf-weread-tests-index-upsert-updates-a-changed-thought ()
  "Re-indexing a changed thought updates the stored row instead of adding one."
  (etaf-weread-tests--with-index
    (setq etaf-weread-tests--requests nil)
    (let ((app (etaf-weread-tests--session)))
      (setq etaf-weread-tests--thought "原来的想法")
      (etaf-weread-show-book app "1" 'notes)
      (should (= (etaf-weread-index-search app "原来的想法") 1))
      (setq etaf-weread-tests--thought "改过的想法")
      (etaf-weread-index-notebook app t)
      ;; Every scripted highlight carries the current thought, so both books
      ;; now match it while the old text is gone.
      (should (= (etaf-weread-index-search app "改过的想法") 2))
      (should (= (etaf-weread-index-search app "原来的想法") 0))
      (should (= (etaf-weread-index-search app "") 3)))))

;;; ---------------------------------------------------------------------------
;;; Failures, theme and presentation
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-weread-tests-backend-failure-is-reported-not-signaled ()
  "A failing backend reply lands in the status line while the reader stays usable."
  (setq etaf-weread-tests--requests nil
        etaf-weread-tests--error "登录态失效")
  (unwind-protect
      (let ((app (etaf-weread-tests--session)))
        (etaf-weread-refresh app)
        (should (equal (plist-get (etaf-weread-state app) :error) "登录态失效"))
        (should (string-match-p "登录态失效" (plist-get (etaf-weread-state app) :message)))
        (etaf-weread-locate app :notebook)
        (should (= (plist-get (etaf-weread-state app) :rows-total) 0)))
    (setq etaf-weread-tests--error nil)))

(ert-deftest etaf-weread-tests-missing-backend-script-is-reported ()
  "A client whose skill script is missing reports an error instead of signaling."
  (let* ((directory (make-temp-file "etaf-weread-missing-" t))
         (app (etaf-weread-create
               :client (etaf-weread-make-client :skill-directory directory))))
    (unwind-protect
        (progn
          (etaf-weread-refresh app)
          (should (string-match-p "weread skill script is missing"
                                  (plist-get (etaf-weread-state app) :message))))
      (delete-directory directory t))))

(ert-deftest etaf-weread-tests-theme-tokens-cover-both-palettes ()
  "Colours resolve per palette, and the UI defaults follow the mode."
  (unwind-protect
      (let ((etaf-weread-theme-mode 'dark))
        (should (string-match-p "\\`#[0-9A-Fa-f]\\{6\\}\\'" (etaf-weread-color :accent)))
        (should-error (etaf-weread-color :nonsense) :type 'etaf-weread-error)
        (dolist (key '(:bg :panel :panel2 :panel3 :line :ink :muted :dim
                       :accent :accent-soft :gold :ok :warn :danger :danger-bg
                       :info :selected :meter :cover :quote))
          (dolist (mode '(dark light))
            (should (string-match-p "\\`#[0-9A-Fa-f]\\{6\\}\\'"
                                    (etaf-weread-color key mode)))))
        (let ((dark (etaf-weread-color :bg))
              (defaults (etaf-weread-theme-defaults 'dark)))
          (should (equal (plist-get defaults :ui-bg) dark))
          (should (plist-get defaults :ui-accent))
          (should-not (equal dark (etaf-weread-color :bg 'light)))))
    (setq etaf-weread-theme-mode 'dark)))

(ert-deftest etaf-weread-tests-format-duration-and-progress-bar ()
  "Reading time and the text progress bar keep their documented shapes."
  (should (equal (etaf-weread-format-duration 4384) "1小时13分"))
  (should (equal (etaf-weread-format-duration 600) "10分"))
  (should (equal (etaf-weread-format-duration 0) ""))
  (should (equal (etaf-weread-progress-bar 0 4) "░░░░"))
  (should (equal (etaf-weread-progress-bar 100 4) "████"))
  (should (equal (etaf-weread-progress-bar 50 4) "██░░")))

;;; ---------------------------------------------------------------------------
;;; Mounting and default client
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-weread-tests-mount-renders-and-revives ()
  "Mounting paints the shelf and killing the buffer lets the session mount again."
  (setq etaf-weread-tests--requests nil)
  (let ((app (etaf-weread-tests--session))
        (buffer (get-buffer-create " *etaf-weread-tests-mount*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-weread-view app)
                      (list :viewport-width 1200 :viewport-height 40))
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "书1" text))
              (should (string-match-p "全部书架" text))))
          ;; The highlight pane renders a keyed list too; mount it so duplicate
          ;; or invalid keys fail here instead of in a live frame.
          (etaf-weread-show-book app "1" 'notes)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "详情节1" text))
              (should (string-match-p "划线" text))))
          ;; The shared Progress, Tabs, Statistic and Empty controls must render
          ;; in the panes that compose them.
          (etaf-weread-show-book app "1" 'detail)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "已读" text))
              (should (string-match-p "目录 2" text))))
          (etaf-weread-locate app :stats)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "阅读统计" text))
              (should (string-match-p "读完" text))))
          (kill-buffer buffer)
          (let ((again (get-buffer-create " *etaf-weread-tests-mount*")))
            (etaf-mount again (etaf-weread-view app)
                        (list :viewport-width 1200 :viewport-height 40))
            (with-current-buffer again
              (should (string-match-p "书1"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))))))
      (when (get-buffer " *etaf-weread-tests-mount*")
        (kill-buffer " *etaf-weread-tests-mount*")))))

(ert-deftest etaf-weread-tests-cached-list-refreshes-without-a-loading-state ()
  "A cached list is compared in the background and replaced only when it changed.
The first visit loads in the foreground; the next visit paints the cache at
once and refreshes it without a loading state, so the sidebar never flickers;
a changed reply then replaces the rows."
  (setq etaf-weread-tests--requests nil)
  (let* ((app nil)
         (loading-at-request 'unseen)
         (client (lambda (request callback)
                   (when (equal (plist-get request :op) :shelf)
                     (setq loading-at-request
                           (plist-get (etaf-weread-state app) :loading)))
                   (etaf-weread-tests--client request callback))))
    (setq app (etaf-weread-tests--session client))
    ;; First visit: a foreground load, with its loading state.
    (etaf-weread-locate app :shelf)
    (should (eq loading-at-request t))
    (should (= 2 (length (plist-get (etaf-weread-state app) :items))))
    ;; Next visit: cache first, background compare, no loading state.
    (setq etaf-weread-tests--requests nil
          loading-at-request 'unseen)
    (etaf-weread-locate app :reading)
    (etaf-weread-locate app :shelf)
    (should (eq loading-at-request nil))
    (should (= 2 (length (plist-get (etaf-weread-state app) :items))))
    ;; A changed reply replaces the cached rows.
    (setq etaf-weread-tests--book-count 3)
    (unwind-protect
        (progn
          (etaf-weread-locate app :reading)
          (etaf-weread-locate app :shelf)
          (should (= 3 (length (plist-get (etaf-weread-state app) :items)))))
      (setq etaf-weread-tests--book-count 2))
    ;; Re-opening the section that is already shown keeps the reader's place.
    (etaf-weread-move-selection app 1)
    (etaf-weread-locate app :shelf)
    (should (= 1 (plist-get (etaf-weread-state app) :selection)))))

(ert-deftest etaf-weread-tests-prefetch-warms-lists-and-stops-on-close ()
  "A mounted reader warms unopened lists in the background and stops on close.
The timer loads a list that was never opened, so opening it later shows cached
rows and refreshes them without a loading state; killing the buffer cancels
the timer."
  (setq etaf-weread-tests--requests nil)
  (let* ((etaf-weread-prefetch-interval 0.05)
         ;; 预热的是「还没缓存」的列表；把过期阈值放长，避免过期刷新把预热挤出循环。
         (etaf-weread-library-refresh-interval 3600)
         (app nil)
         (loading-at-request nil)
         (client (lambda (request callback)
                   (push (cons (plist-get request :op)
                               (plist-get (etaf-weread-state app) :loading))
                         loading-at-request)
                   (etaf-weread-tests--client request callback)))
         (buffer (get-buffer-create " *etaf-weread-tests-prefetch*")))
    (setq app (etaf-weread-tests--session client))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-weread-view app)
                      (list :viewport-width 1200 :viewport-height 40))
          (etaf-weread-locate app :shelf)
          (should (etaf-weread-tests--wait
                   (lambda () (> (etaf-weread-tests--request-count :notebook) 0))))
          (should (etaf-weread-tests--wait
                   (lambda () (> (etaf-weread-tests--request-count :stats) 0))))
          ;; A warmed section opens from its cache, without a loading state.
          (setq loading-at-request nil)
          (etaf-weread-locate app :notebook)
          (should (eq (cdr (assq :notebook loading-at-request)) nil))
          (should (etaf-weread-tests--wait
                   (lambda () (plist-get (etaf-weread-state app) :items))))
          (kill-buffer buffer)
          (setq etaf-weread-tests--requests nil)
          (accept-process-output nil 0.3)
          (should (= 0 (etaf-weread-tests--request-count :shelf))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-weread-tests-prefetch-pauses-while-hidden ()
  "A reader no window shows pauses its background refreshes until shown again."
  (setq etaf-weread-tests--requests nil)
  (let* ((etaf-weread-prefetch-interval 0.05)
         (etaf-weread-library-refresh-interval 0.05)
         (app (etaf-weread-tests--session)))
    (unwind-protect
        (let* ((buffer (etaf-weread-open app))
               (other (get-buffer-create " *etaf-weread-tests-other*")))
          (etaf-weread-locate app :shelf)
          (should (etaf-weread-tests--wait
                   (lambda () (> (etaf-weread-tests--request-count :shelf) 3))))
          ;; 藏起来：预热停下（等一拍再清账，避免把在途请求算进隐藏期）。
          (set-window-buffer (get-buffer-window buffer t) other)
          (accept-process-output nil 0.2)
          (setq etaf-weread-tests--requests nil)
          (accept-process-output nil 0.5)
          (should (= 0 (etaf-weread-tests--request-count :shelf)))
          ;; 重新显示：预热恢复。
          (set-window-buffer (get-buffer-window other t) buffer)
          (should (etaf-weread-tests--wait
                   (lambda () (> (etaf-weread-tests--request-count :shelf) 0)))))
      (etaf-weread-close))))

(ert-deftest etaf-weread-tests-auth-failure-pauses-refreshes ()
  "A refresh that fails because the login expired pauses the warmer for good.
A successful foreground load clears the pause, so signing in again resumes it."
  (setq etaf-weread-tests--requests nil)
  (let* ((etaf-weread-prefetch-interval 0.05)
         ;; 让已缓存的列表保持新鲜，预热就会去补还没缓存的节（含 :notebook）。
         (etaf-weread-library-refresh-interval 3600)
         (fail-auth t)
         (app nil)
         (client (lambda (request callback)
                   ;; 失败分支自己记账：脚本客户端只会记成功的请求。
                   (if (and fail-auth (eq (plist-get request :op) :notebook))
                       (progn
                         (push request etaf-weread-tests--requests)
                         (funcall callback
                                  (list :error "微信读书接口错误（登录超时）"
                                        :hint "pi-skill weread login"
                                        :code "auth")))
                     (etaf-weread-tests--client request callback)))))
    (setq app (etaf-weread-tests--session client))
    (unwind-protect
        (progn
          (etaf-weread-open app)
          (etaf-weread-locate app :shelf)
          (should (etaf-weread-tests--wait
                   (lambda () (> (etaf-weread-tests--request-count :notebook) 0))))
          ;; 暂停后不再有任何后台刷新（用快照比较，不清理账目）。
          (accept-process-output nil 0.2)
          (let ((shelf-before (etaf-weread-tests--request-count :shelf))
                (notebook-before (etaf-weread-tests--request-count :notebook)))
            (accept-process-output nil 0.5)
            (should (= shelf-before (etaf-weread-tests--request-count :shelf)))
            (should (= notebook-before (etaf-weread-tests--request-count :notebook))))
          ;; 前台加载成功解除暂停：预热恢复去补未缓存的节。
          (let ((notebook-before (etaf-weread-tests--request-count :notebook)))
            (setq fail-auth nil)
            (etaf-weread-locate app :shelf)
            (should (etaf-weread-tests--wait
                     (lambda ()
                       (> (etaf-weread-tests--request-count :notebook)
                          notebook-before))))))
      (etaf-weread-close))))

(ert-deftest etaf-weread-tests-status-hints-fit-their-layout ()
  "Each layout paints its binding hint whole instead of clipping it.
The wide status bar and the compact tab row choose a hint that fits the
columns they are painted in, so no layout cuts the summary off."
  (setq etaf-weread-tests--requests nil)
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-hints*")
        (app (etaf-weread-tests--session))
        (headless (get-buffer-create " *etaf-weread-tests-hints-wide*"))
        (narrow nil))
    (unwind-protect
        (progn
          ;; Headless (wide): the status bar carries the whole summary.
          (etaf-mount headless (etaf-weread-view app)
                      (list :viewport-width 1200 :viewport-height 40))
          (with-current-buffer headless
            (should (string-match-p
                     (regexp-quote "g 刷新 · v 笔记 · o 浏览器 · E 导出 · T 深浅色 · ? 帮助")
                     (buffer-substring-no-properties (point-min) (point-max)))))
          (kill-buffer headless)
          ;; A medium frame (the batch window is 80 columns): the compact tab
          ;; row still fits the whole summary next to the switch.
          (let ((buffer (etaf-weread-open app)))
            (etaf-weread-refresh app)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (should (string-match-p
                       (regexp-quote "j/k 选择 · RET 打开 · v 切换面板")
                       (buffer-substring-no-properties (point-min) (point-max)))))
            ;; A narrow frame: only the short hint fits.
            (setq narrow (split-window (selected-window) 25 'right))
            (set-window-buffer (selected-window)
                               (get-buffer-create " *etaf-weread-tests-other*"))
            (set-window-buffer narrow buffer)
            (select-window narrow)
            (etaf-weread-refresh app)
            (etaf-runtime-refit (etaf-runtime-for-buffer buffer) 371 24)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p (regexp-quote "? 帮助") text))
                (should-not (string-match-p
                             (regexp-quote "j/k 选择 · RET 打开 · v 切换面板")
                             text))))))
      (when (and narrow (window-live-p narrow)
                 (not (eq narrow (selected-window))))
        (delete-window narrow))
      (when (get-buffer " *etaf-weread-tests-hints*")
        (kill-buffer " *etaf-weread-tests-hints*"))
      (when (buffer-live-p headless) (kill-buffer headless))
      (when (get-buffer " *etaf-weread-tests-other*")
        (kill-buffer " *etaf-weread-tests-other*")))))

(ert-deftest etaf-weread-tests-section-switches-return-to-the-list-on-compact ()
  "A section switch shows the list pane again on a compact frame.
A compact frame shows one pane at a time, so browsing another section must
not leave the reader on the side pane it was showing; a wide frame keeps
its pane choice."
  (setq etaf-weread-tests--requests nil)
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-compact*")
        (app (etaf-weread-tests--session))
        (headless (get-buffer-create " *etaf-weread-tests-compact-wide*"))
        (narrow nil))
    (unwind-protect
        (progn
          ;; Headless (wide): a section switch keeps the pane.
          (etaf-mount headless (etaf-weread-view app)
                      (list :viewport-width 1200 :viewport-height 40))
          (etaf-weread-show-book app "1" 'notes)
          (etaf-weread-locate app :notebook)
          (should (eq 'notes (plist-get (etaf-weread-state app) :pane)))
          (kill-buffer headless)
          ;; Compact: the same switch brings the list back into view.
          (let ((buffer (etaf-weread-open app)))
            (setq narrow (split-window (selected-window) 25 'right))
            (set-window-buffer (selected-window)
                               (get-buffer-create " *etaf-weread-tests-other*"))
            (set-window-buffer narrow buffer)
            (select-window narrow)
            (etaf-weread-refresh app)
            (etaf-weread-show-book app "1" 'notes)
            (should (eq 'notes (plist-get (etaf-weread-state app) :pane)))
            (etaf-weread-locate app :notebook)
            (should (eq 'list (plist-get (etaf-weread-state app) :pane)))))
      (when (and narrow (window-live-p narrow)
                 (not (eq narrow (selected-window))))
        (delete-window narrow))
      (when (get-buffer " *etaf-weread-tests-compact*")
        (kill-buffer " *etaf-weread-tests-compact*"))
      (when (get-buffer " *etaf-weread-tests-other*")
        (kill-buffer " *etaf-weread-tests-other*"))
      (when (buffer-live-p headless) (kill-buffer headless)))))

(ert-deftest etaf-weread-tests-ret-opens-the-selection ()
  "Pressing RET after moving the selection opens the selected book.
The renderer only activates a Host under point, and j/k leave point where it
was, so the reader falls back to the selection the manual promises."
  (setq etaf-weread-tests--requests nil)
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-ret*")
        (app (etaf-weread-tests--session)))
    (unwind-protect
        (let ((buffer (etaf-weread-open app)))
          (with-current-buffer buffer
            (execute-kbd-macro "j")
            (should (= 1 (plist-get (etaf-weread-state app) :selection)))
            (execute-kbd-macro (kbd "RET"))
            (should (eq 'detail (plist-get (etaf-weread-state app) :pane)))
            (should (equal "2" (plist-get (plist-get (etaf-weread-state app) :detail)
                                           :id)))))
      (when (get-buffer " *etaf-weread-tests-ret*")
        (kill-buffer " *etaf-weread-tests-ret*")))))

(ert-deftest etaf-weread-tests-library-lists-and-parses-local-books ()
  "The local library lists a directory and reads TXT and EPUB books.
A local book needs no backend: the directory scan and the file parsers turn
it into the same chapter shape a book reply uses."
  (let* ((fixtures (expand-file-name "fixtures" etaf-weread-tests--directory))
         (directory (make-temp-file "weread-library-" t)))
    (unwind-protect
        (progn
          (dolist (name '("local-a.txt" "local-mini.epub"))
            (copy-file (expand-file-name name fixtures)
                       (expand-file-name name directory) t))
          ;; An unsupported file is written here instead of kept as a fixture.
          (write-region "not a book" nil (expand-file-name "notes.pdf" directory))
          (let ((books (etaf-weread-library-books directory)))
            (should (= 2 (length books)))
            (should (equal '("epub" "txt")
                           (sort (mapcar (lambda (book) (plist-get book :format)) books)
                                 #'string<))))
          (let* ((content (etaf-weread-library-content
                           (expand-file-name "local-a.txt" directory)))
                 (chapters (plist-get content :chapters)))
            (should (equal "local-a" (plist-get content :title)))
            (should (= 3 (length chapters)))
            (should (string-match-p "第一章正文" (plist-get (car chapters) :text)))
            (should (string-match-p "第三章正文" (plist-get (car (last chapters)) :text))))
          (let* ((content (etaf-weread-library-content
                           (expand-file-name "local-mini.epub" directory)))
                 (chapters (plist-get content :chapters)))
            (should (= 2 (length chapters)))
            (should (string-match-p "第一章正文" (plist-get (car chapters) :text)))
            (should (string-match-p "第二章正文" (plist-get (car (last chapters)) :text)))
            ;; The XML declaration every XHTML entry carries is markup, not
            ;; chapter text: the heading line must not surface in the title.
            (should (equal "第一章" (plist-get (car chapters) :title)))
            (should (equal "第二章" (plist-get (car (last chapters)) :title))))
          (should-error (etaf-weread-library-content
                         (expand-file-name "notes.pdf" directory))
                        :type 'etaf-weread-error)
          (should-not (etaf-weread-library-books (expand-file-name "missing" directory))))
      (delete-directory directory t))))

(ert-deftest etaf-weread-tests-local-book-reading ()
  "A local book opens in the reading pane and turns chapters.
The section lists the directory, opening a book publishes its first chapter,
the chapter keys move through the book and the pane scroll budget follows the
wrapped text."
  (setq etaf-weread-tests--requests nil)
  (let* ((fixtures (expand-file-name "fixtures" etaf-weread-tests--directory))
         (directory (make-temp-file "weread-reading-" t))
         (etaf-weread-buffer-name " *etaf-weread-tests-reading*")
         (app (etaf-weread-tests--session)))
    (unwind-protect
        (let ((etaf-weread-library-directory directory))
          (copy-file (expand-file-name "local-a.txt" fixtures)
                     (expand-file-name "local-a.txt" directory) t)
          (etaf-weread-locate app :local)
          (should (= 1 (length (plist-get (etaf-weread-state app) :items))))
          (should (equal "local-a" (plist-get (car (plist-get (etaf-weread-state app) :items)) :title)))
          (let ((buffer (etaf-weread-open app)))
            (should (= 3 (etaf-weread-open-local-book
                          app (expand-file-name "local-a.txt" directory))))
            ;; A compact frame shows one pane at a time, and the reading pane
            ;; is the one a local chapter needs; it must paint its lines.
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (should (string-match-p
                       "第一章正文"
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (let ((state (etaf-weread-state app)))
              (should (eq 'reader (plist-get state :pane)))
              (should (= 0 (plist-get (plist-get state :local) :index)))
              (should (string-match-p "第一章正文"
                                      (mapconcat (lambda (line) (plist-get line :text))
                                                 (plist-get state :reader-lines) " ")))
              (should (= (length (plist-get state :reader-lines))
                         (plist-get state :pane-total)))
              (should (string-match-p "第 1/3 章" (plist-get state :reader-title))))
            ;; A real key turns the chapter while the reading pane is shown.
            (with-current-buffer buffer (execute-kbd-macro (kbd "<next>")))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (should (string-match-p
                       "第二章正文"
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (let ((state (etaf-weread-state app)))
              (should (= 1 (plist-get (plist-get state :local) :index)))
              (should (string-match-p "第二章正文"
                                      (mapconcat (lambda (line) (plist-get line :text))
                                                 (plist-get state :reader-lines) " "))))
            (should (= 3 (etaf-weread-read-chapter app 3)))
            (should (string-match-p "第三章正文"
                                    (mapconcat (lambda (line) (plist-get line :text))
                                               (plist-get (etaf-weread-state app) :reader-lines)
                                               " ")))
            ;; Clamping: an index past the end stays on the last chapter.
            (should (= 3 (etaf-weread-read-chapter app 99)))
            (kill-buffer buffer)))
      (delete-directory directory t))))

(defmacro etaf-weread-tests--with-local-books (directory-var &rest body)
  "Run BODY with a disposable local library DIRECTORY-VAR points at.
The library holds the fixture books and `etaf-weread-library-directory' points
at it while BODY runs, so the section scan reads only fixtures."
  (declare (indent 1) (debug t))
  `(let* ((fixtures (expand-file-name "fixtures" etaf-weread-tests--directory))
          (,directory-var (make-temp-file "weread-local-books-" t))
          (etaf-weread-library-directory ,directory-var))
     (unwind-protect
         (progn
           (dolist (name '("local-a.txt" "local-mini.epub"))
             (copy-file (expand-file-name name fixtures)
                        (expand-file-name name ,directory-var) t))
           ,@body)
       (delete-directory ,directory-var t))))

(ert-deftest etaf-weread-tests-reading-pane-owns-the-frame-body ()
  "An open local chapter replaces the book list in a wide frame.
The reading pane is what the session is for, so it takes the frame's body and
the list steps aside; leaving the chapter for the book card brings the list
back.  The session is headless, so its layout is the wide one the list would
otherwise share the body with."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let ((app (etaf-weread-tests--session))
          (buffer (get-buffer-create " *etaf-weread-tests-owns*")))
      (unwind-protect
          (progn
            (etaf-weread-locate app :local)
            (etaf-mount buffer (etaf-weread-view app)
                        (list :viewport-width 1200 :viewport-height 40))
            (with-current-buffer buffer
              (should (string-match-p
                       "搜索书名或作者"
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (= 3 (etaf-weread-open-local-book
                          app (expand-file-name "local-a.txt" directory))))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "第一章正文" text))
                ;; The search field is painted by the list alone.
                (should-not (string-match-p "搜索书名或作者" text))))
            ;; Leaving the chapter for the book card shows the list again.
            (etaf-weread-toggle-pane app)
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (should (string-match-p
                       "搜索书名或作者"
                       (buffer-substring-no-properties (point-min) (point-max))))))
        (kill-buffer buffer)))))

(ert-deftest etaf-weread-tests-reading-width-and-zen ()
  "`[' and `]' refit the reading column and `f' gives the frame to the chapter.
The column is wrapped again on every width change, so no line clips, and the
reading-only layout drops the navigation and the footer."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let ((app (etaf-weread-tests--session))
          (buffer (get-buffer-create " *etaf-weread-tests-zen*")))
      (unwind-protect
          (progn
            (etaf-weread-locate app :local)
            (etaf-weread-open-local-book app (expand-file-name "local-a.txt" directory))
            (etaf-mount buffer (etaf-weread-view app)
                        (list :viewport-width 1200 :viewport-height 40))
            (should (= 44 (plist-get (etaf-weread-state app) :reader-columns)))
            (let ((before (length (plist-get (etaf-weread-state app) :reader-lines))))
              (should (= 32 (etaf-weread-adjust-reading-measure app -12)))
              (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
              (let* ((state (etaf-weread-state app))
                     (lines (plist-get state :reader-lines))
                     (widths (mapcar (lambda (line)
                                       (string-width (plist-get line :text)))
                                     lines)))
                (should (= 32 (plist-get state :reader-columns)))
                (should (> (length lines) before))
                (should (<= (apply #'max widths) 32))))
            (should (eq t (etaf-weread-toggle-zen app)))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "第一章正文" text))
                ;; The section navigation owns that name and zen hides it.
                (should-not (string-match-p "全部书架" text))))
            (should-not (etaf-weread-toggle-zen app))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (should (string-match-p
                       "全部书架"
                       (buffer-substring-no-properties (point-min) (point-max))))))
        (kill-buffer buffer)))))

(ert-deftest etaf-weread-tests-reading-font-presets ()
  "The reading font cycles small, medium and large and survives the session.
The medium preset keeps the frame's own font, a scaled preset is published in
 the session state together with the row height the page budget counts, and an
unknown preset signals without changing the session."
  (setq etaf-weread-tests--requests nil)
  (let* ((file (make-temp-file "weread-font-" nil ".eld"))
         (etaf-weread-tests--settings file)
         (app (etaf-weread-tests--session)))
    (unwind-protect
        (progn
          (should (eq 'medium (plist-get (etaf-weread-state app) :reader-font)))
          ;; The frame font is the default, so no pixel size is forced.
          (should-not (plist-get (etaf-weread-state app) :reader-font-size))
          ;; The cycle is medium, large, small and back to medium.
          (should (eq 'large (etaf-weread-cycle-reading-font app)))
          (should (eq 'small (etaf-weread-cycle-reading-font app)))
          (should (eq 'medium (etaf-weread-cycle-reading-font app)))
          (should (eq 'large (etaf-weread-set-reading-font app 'large)))
          (should (eq 'large (plist-get (etaf-weread-state app) :reader-font)))
          ;; An unknown preset is rejected and the session keeps its choice.
          (should-error (etaf-weread-set-reading-font app 'huge)
                        :type 'etaf-weread-error)
          (should (eq 'large (plist-get (etaf-weread-state app) :reader-font)))
          ;; A fresh session on the same file starts with the stored preset.
          (let ((again (etaf-weread-tests--session)))
            (should (eq 'large (plist-get (etaf-weread-state again) :reader-font)))))
      (setq etaf-weread-tests--settings nil)
      (ignore-errors (delete-file file)))))

(ert-deftest etaf-weread-tests-reader-preferences-persist ()
  "The appearance and the reading width are kept for the next session.
A reader that forgets the chosen width and palette on every restart is not a
reader, so both are stored in `etaf-weread-settings-file'."
  (let* ((file (make-temp-file "weread-settings-" nil ".eld"))
         (original etaf-weread-theme-mode)
         (etaf-weread-tests--settings file)
         (app (etaf-weread-tests--session)))
    (unwind-protect
        (progn
          (setq etaf-weread-theme-mode 'dark)
          (should (= 44 (plist-get (etaf-weread-state app) :reader-measure)))
          (should (= 50 (etaf-weread-adjust-reading-measure app 6)))
          (should (eq 'light (etaf-weread-cycle-theme app)))
          (should (eq 'sepia (etaf-weread-cycle-theme app)))
          (should (eq 'dark (etaf-weread-cycle-theme app)))
          (should (eq 'light (etaf-weread-cycle-theme app)))
          ;; A fresh session on the same file starts where the last one left.
          (let ((again (etaf-weread-tests--session)))
            (should (= 50 (plist-get (etaf-weread-state again) :reader-measure)))
            (should (eq 'light etaf-weread-theme-mode))))
      (setq etaf-weread-theme-mode original
            etaf-weread-tests--settings nil)
      (ignore-errors (delete-file file)))))

(ert-deftest etaf-weread-tests-local-rows-do-not-ask-the-shelf ()
  "Selecting a local row never requests it from the backend.
A local book's id is its file path and the shelf holds no such book, so
following the selection as if it were a store book would paint a not-found
error over the reader."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let ((etaf-weread-detail-follow-delay 0)
          (app (etaf-weread-tests--session)))
      ;; Sessions from earlier tests may still have a detail follow pending;
      ;; let those fire before recording, so only this session's requests
      ;; are read below.
      (sleep-for 0.5)
      (setq etaf-weread-tests--requests nil)
      (etaf-weread-locate app :local)
      (should (= 2 (length (plist-get (etaf-weread-state app) :items))))
      (setq etaf-weread-tests--requests nil)
      (etaf-weread-move-selection app 1)
      (sleep-for 0.1)
      (should-not (etaf-weread-tests--request :book))
      (should-not (plist-get (etaf-weread-state app) :error))
      ;; A store row is still followed: the guard is about local rows, not
      ;; about the detail follow itself.
      (etaf-weread-locate app :shelf)
      (setq etaf-weread-tests--requests nil)
      (etaf-weread-move-selection app 1)
      (sleep-for 0.1)
      (should (etaf-weread-tests--request :book)))))

(ert-deftest etaf-weread-tests-reading-spread-and-indent ()
  "A wide reading pane shows two columns and indents Chinese paragraphs.
The second column carries the lines the first cannot hold, a paragraph after
a blank line starts with the full-width indent, and the first line stays flush
because it carries the chapter heading."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let ((app (etaf-weread-tests--session))
          (buffer (get-buffer-create " *etaf-weread-tests-spread*")))
      (unwind-protect
          (progn
            (etaf-weread-locate app :local)
            (etaf-weread-open-local-book app (expand-file-name "local-a.txt" directory))
            ;; A narrower measure lets two columns share a batch frame.
            (should (= 24 (etaf-weread-adjust-reading-measure app -20)))
            (should (= 2 (plist-get (etaf-weread-state app) :reader-shown)))
            (let* ((state (etaf-weread-state app))
                   (rows (plist-get state :pane-rows))
                   (lines (plist-get state :reader-lines)))
              (should (> (length lines) (1+ rows)))
              ;; Paragraph indent: the heading stays flush, a later paragraph
              ;; starts with the full-width indent.
              (should-not (string-prefix-p "    " (plist-get (car lines) :text)))
              (should (seq-some (lambda (line) (string-prefix-p "    " (plist-get line :text)))
                                lines))
              (etaf-mount buffer (etaf-weread-view app)
                          (list :viewport-width 1200 :viewport-height 40))
              (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
              (with-current-buffer buffer
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  ;; The line that opens the second column is painted too, so
                  ;; both columns carry their own slice of the chapter.
                  (should (string-match-p
                           (regexp-quote (plist-get (nth rows lines) :text)) text)))
                (should (string-match-p
                         (regexp-quote (plist-get (nth 1 lines) :text))
                         (buffer-substring-no-properties (point-min) (point-max))))))
            ;; One column is a key away, and the choice survives the session.
            (should (= 1 (etaf-weread-toggle-reading-spread app)))
            (should (= 1 (plist-get (etaf-weread-state app) :reader-shown)))
            (should (= 2 (etaf-weread-toggle-reading-spread app)))
            (should (= 2 (plist-get (etaf-weread-state app) :reader-shown)))
            ;; The cycle returns to automatic and stays there.
            (should (eq 'auto (etaf-weread-toggle-reading-spread app)))
            (should (= 2 (plist-get (etaf-weread-state app) :reader-shown))))
        (kill-buffer buffer)))))

(ert-deftest etaf-weread-tests-remembers-the-reading-position ()
  "Reopening a local book continues where the last session stopped.
The chapter is restored exactly and the position inside it is stored as a
fraction, so it survives even a different reading width or frame size."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let* ((file (make-temp-file "weread-position-" nil ".eld"))
           (etaf-weread-tests--settings file)
           (etaf-weread-position-save-delay 0)
           ;; A book long enough that the first chapter scrolls.
           (path (expand-file-name "long.txt" directory)))
      (unwind-protect
          (progn
            (with-temp-file path
              (insert "第一章 长文\n")
              (dotimes (index 40)
                (insert (format "第%d段：这是用来填满阅读栏的一段文字，反复出现以便产生足够的行数。\n\n"
                                index)))
              (insert "第二章 短章\n这一章很短，只用来验证章位的恢复。\n"))
            (let ((app (etaf-weread-tests--session)))
              (etaf-weread-locate app :local)
              (etaf-weread-open-local-book app path)
              (should (= 24 (etaf-weread-adjust-reading-measure app -20)))
              (etaf-weread-scroll-pane app 6)
              (sleep-for 0.05)
              (should (= 6 (plist-get (etaf-weread-state app) :pane-scroll))))
            ;; The next session continues in the same chapter and place, and a
            ;; chapter turned in between is the one a later session restores.
            (let* ((again (etaf-weread-tests--session))
                   (state nil))
              (etaf-weread-locate again :local)
              (etaf-weread-open-local-book again path)
              (setq state (etaf-weread-state again))
              (should (= 0 (plist-get (plist-get state :local) :index)))
              (should (= 6 (plist-get state :pane-scroll)))
              (should (= 2 (etaf-weread-read-chapter again 2))))
            (let* ((third (etaf-weread-tests--session))
                   (state nil))
              (etaf-weread-locate third :local)
              (etaf-weread-open-local-book third path)
              (setq state (etaf-weread-state third))
              (should (= 1 (plist-get (plist-get state :local) :index)))
              (should (= 0 (plist-get state :pane-scroll)))))
        (ignore-errors (delete-file file))))))

(ert-deftest etaf-weread-tests-auto-scroll-advances-turns-and-stops ()
  "Auto-scroll moves the chapter by itself, turns it and stops at the book end.
The timer must be bounded by the book and released when it is turned off or
when there is nothing to scroll, or it would keep moving a closed reader."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let* ((etaf-weread-auto-scroll-interval 0.05)
           (app (etaf-weread-tests--session))
           (position (lambda ()
                       (let ((state (etaf-weread-state app)))
                         (list (plist-get (plist-get state :local) :index)
                               (plist-get state :pane-scroll))))))
      ;; Without an open chapter there is nothing to scroll.
      (should-not (etaf-weread-toggle-auto-scroll app))
      (should-not (plist-get (etaf-weread-state app) :auto-scroll))
      (should (= 3 (etaf-weread-open-local-book
                    app (expand-file-name "local-a.txt" directory))))
      (should (eq t (etaf-weread-toggle-auto-scroll app)))
      (should (eq t (plist-get (etaf-weread-state app) :auto-scroll)))
      (let ((before (funcall position)))
        (sleep-for 0.2)
        (should-not (equal before (funcall position))))
      ;; The last line of the last chapter stops it instead of scrolling on.
      (etaf-weread-read-chapter app 3)
      (sleep-for 0.2)
      (etaf-weread-scroll-pane app (plist-get (etaf-weread-state app) :pane-total))
      (sleep-for 0.2)
      (should-not (plist-get (etaf-weread-state app) :auto-scroll))
      ;; Turning it off releases the timer: nothing moves afterwards.
      (etaf-weread-read-chapter app 1)
      (should (eq t (etaf-weread-toggle-auto-scroll app)))
      (etaf-weread-scroll-pane app (- (plist-get (etaf-weread-state app) :pane-scroll)))
      (should-not (etaf-weread-toggle-auto-scroll app))
      (should-not (plist-get (etaf-weread-state app) :auto-scroll))
      (sleep-for 0.2)
      (should (equal '(0 0) (funcall position))))))

(defun etaf-weread-tests--local-notes-client (request callback)
  "Answer REQUEST with a notebook and highlights for the local fixture.
The notebook lists `local-a' and the highlights share its text; one highlight
does not exist in the local book and must be dropped."
  (push request etaf-weread-tests--requests)
  (pcase (plist-get request :op)
    (:notebook
     (funcall callback
              (list :ok
                    (list :ok t
                          :data (list :books (list (list :bookId "77"
                                                         :title "local-a"
                                                         :counts (list :notes 3 :reviews 1))))))))
    (:notes
     (funcall callback
              (list :ok
                    (list :ok t
                          :data (list :book (list :bookId "77" :title "local-a")
                                      :highlights
                                      (list (list :bookmarkId "n1" :chapterName "第一章"
                                                  :range "1-2"
                                                  :markText "习惯的起点总是一件很小的事"
                                                  :createTime 1)
                                            (list :bookmarkId "n2" :chapterName "第三章"
                                                  :range "5-6"
                                                  :markText "不再追逐一时的强度"
                                                  :createTime 2)
                                            (list :bookmarkId "n3" :chapterName "第二章"
                                                  :range "9-9"
                                                  :markText "本地书里没有的句子"
                                                  :createTime 3))
                                      :reviews (list (list :reviewId "r1" :range "1-2"
                                                           :content "我的想法"
                                                           :createTime 4)))))))
    (_ (etaf-weread-tests--client request callback))))

(ert-deftest etaf-weread-tests-local-notes-overlay ()
  "The account's highlights are matched to the local book and navigable.
A highlight whose text is in the local book marks its lines, one it does not
contain is dropped, `N' walks the matches and a thought is reported."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let* ((app (etaf-weread-tests--session #'etaf-weread-tests--local-notes-client))
           (path (expand-file-name "local-a.txt" directory)))
      (etaf-weread-locate app :local)
      (etaf-weread-open-local-book app path)
      (let* ((notes (plist-get (etaf-weread-state app) :local-notes))
             (matches (plist-get notes :notes)))
        (should (equal "77" (plist-get notes :book-id)))
        (should (equal "local-a" (plist-get notes :title)))
        ;; The highlight missing from the local text is dropped.
        (should (= 2 (length matches)))
        (should (equal '(0 2) (mapcar (lambda (note) (plist-get note :chapter))
                                      matches)))
        (should (equal "我的想法" (plist-get (car matches) :thought))))
      ;; The chapter that carries a highlight marks its lines.
      (should (seq-some (lambda (line) (plist-get line :note))
                        (plist-get (etaf-weread-state app) :reader-lines)))
      ;; `N' walks the matches and wraps after the last one.
      (let* ((matches (plist-get (plist-get (etaf-weread-state app) :local-notes)
                                 :notes))
             (first (etaf-weread-next-local-note app)))
        (should (member first matches))
        (etaf-weread-show-local-note app (car (last matches)))
        (should (equal (car matches) (etaf-weread-next-local-note app))))
      ;; A jumped-to note reports its thought in the status line.
      (etaf-weread-show-local-note
       app (car (plist-get (plist-get (etaf-weread-state app) :local-notes)
                           :notes)))
      (should (string-match-p "我的想法"
                              (plist-get (etaf-weread-state app) :message))))))

(defun etaf-weread-tests--binding (path &optional percent)
  "Return a scripted binding of PATH with PERCENT account progress."
  (list :file path :book_id "77" :title "local-a" :source "manual"
        :progress (list :percent (or percent 36) :chapter_idx 3 :reading_time 400)))

(ert-deftest etaf-weread-tests-local-binding-shows-account-progress ()
  "A bound local book shows the account's progress in the list and the head.
The binding is resolved by file path, decorates the local row, and the
session publishes it as `:local-bindings' for the reading head."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let* ((path (expand-file-name "local-a.txt" directory))
           (etaf-weread-tests--bindings (list (etaf-weread-tests--binding path)))
           (app (etaf-weread-tests--session)))
      (etaf-weread-locate app :local)
      (let ((row (seq-find (lambda (row) (equal path (plist-get row :id)))
                           (plist-get (etaf-weread-state app) :items))))
        (should (equal 36 (plist-get row :progress))))
      (etaf-weread-open-local-book app path)
      (let* ((state (etaf-weread-state app))
             (bindings (plist-get state :local-bindings))
             (binding (car bindings)))
        (should (= 1 (length bindings)))
        (should (equal path (plist-get binding :file)))
        (should (equal "77" (plist-get binding :book-id)))
        (should (equal 36 (plist-get binding :percent)))
        (should (equal 3 (plist-get binding :chapter-idx)))))))

(ert-deftest etaf-weread-tests-local-binding-drives-note-matching ()
  "A binding names the account book, so the notebook is not scanned.
The highlights of the bound book are matched to the local text through the
binding instead of a title lookup."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let* ((path (expand-file-name "local-a.txt" directory))
           (etaf-weread-tests--bindings (list (etaf-weread-tests--binding path)))
           (app (etaf-weread-tests--session #'etaf-weread-tests--local-notes-client)))
      (etaf-weread-locate app :local)
      (etaf-weread-open-local-book app path)
      (let* ((notes (plist-get (etaf-weread-state app) :local-notes))
             (matches (plist-get notes :notes)))
        (should (equal "77" (plist-get notes :book-id)))
        (should (= 2 (length matches))))
      (should (= 0 (etaf-weread-tests--request-count :notebook)))
      (should (equal "77" (plist-get (etaf-weread-tests--request :notes) :id))))))

(ert-deftest etaf-weread-tests-sync-progress-writes-the-local-place-back ()
  "The sync action confirms first, sends the local place, and refreshes the binding.
The request carries the open file, its chapter name, the local percent and the
explicit `:yes' the skill needs before it drives the browser."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let* ((path (expand-file-name "local-a.txt" directory))
           (etaf-weread-tests--bindings (list (etaf-weread-tests--binding path)))
           (asked nil)
           (app (etaf-weread-tests--session)))
      (etaf-weread-locate app :local)
      (etaf-weread-open-local-book app path)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq asked t) t)))
        (should (etaf-weread-sync-progress app)))
      (should asked)
      (let ((request (etaf-weread-tests--request :sync-progress)))
        (should (equal path (plist-get request :file)))
        (should (plist-get request :yes))
        (should (equal 120 (plist-get request :timeout)))
        (should (stringp (plist-get request :chapter-title)))
        (should (numberp (plist-get request :percent))))
      ;; The account reply refreshes the published binding.
      (let ((binding (car (plist-get (etaf-weread-state app) :local-bindings))))
        (should (equal 5 (plist-get binding :percent)))
        (should (equal 1 (plist-get binding :chapter-idx)))))))

(ert-deftest etaf-weread-tests-sync-progress-needs-a-binding ()
  "Syncing a local book without a binding signals and keeps the reader intact.
The account is never touched, and the status line tells the reader how to bind
the file."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let* ((path (expand-file-name "local-a.txt" directory))
           (etaf-weread-tests--bindings nil)
           (app (etaf-weread-tests--session)))
      (etaf-weread-locate app :local)
      (etaf-weread-open-local-book app path)
      (should-error (etaf-weread-sync-progress app) :type 'etaf-weread-error)
      (should (null (etaf-weread-tests--request :sync-progress))))))

(ert-deftest etaf-weread-tests-reading-time-and-chapters-accumulate ()
  "The reader records how long a local book was read and which chapters.
The record survives into the next session on the same settings file, and a
book that was never read has no record."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let* ((file (make-temp-file "weread-reading-" nil ".eld"))
           (etaf-weread-tests--settings file)
           (app (etaf-weread-tests--session))
           (path (expand-file-name "local-a.txt" directory)))
      (unwind-protect
          (progn
            (should-not (etaf-weread-reading-stats app path))
            (etaf-weread-locate app :local)
            (etaf-weread-open-local-book app path)
            (let ((stats (etaf-weread-reading-stats app)))
              (should (equal path (plist-get stats :path)))
              (should (equal '(0) (plist-get stats :chapters))))
            (sleep-for 0.3)
            (etaf-weread-read-chapter app 2)
            (let ((stats (etaf-weread-reading-stats app)))
              (should (> (plist-get stats :seconds) 0.2))
              (should (equal '(0 1) (seq-sort #'< (plist-get stats :chapters)))))
            ;; A fresh session on the same file starts from the record.
            (let ((again (etaf-weread-tests--session)))
              (etaf-weread-locate again :local)
              (etaf-weread-open-local-book again path)
              (let ((stats (etaf-weread-reading-stats again)))
                (should (> (plist-get stats :seconds) 0.2))
                (should (equal '(0 1)
                               (seq-sort #'< (plist-get stats :chapters)))))))
        (setq etaf-weread-tests--settings nil)
        (ignore-errors (delete-file file))))))

(ert-deftest etaf-weread-tests-lookup-uses-selection-or-visible-line ()
  "The dictionary key looks the selected text or the line being read up.
An explicit query wins, the reading line changes with the scroll, and a
session with nothing to look up signals instead of calling the backend."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let* ((queries nil)
           (etaf-weread-dictionary-function
            (lambda (query) (push query queries)))
           (app (etaf-weread-tests--session))
           (buffer (get-buffer-create " *etaf-weread-tests-lookup*")))
      (unwind-protect
          (progn
            ;; Nothing open, and no backend is called.
            (should-error (etaf-weread-lookup app) :type 'etaf-weread-error)
            (should-not queries)
            (etaf-weread-locate app :local)
            (etaf-weread-open-local-book
             app (expand-file-name "local-a.txt" directory))
            ;; The line at the top of the visible chapter is the default.
            (let* ((state (etaf-weread-state app))
                   (first (seq-some (lambda (line)
                                      (let ((text (string-trim
                                                   (or (plist-get line :text) ""))))
                                        (unless (string-empty-p text) text)))
                                    (plist-get state :reader-lines))))
              (should (equal first (etaf-weread-lookup app)))
              (should (equal (list first) queries))
              ;; An explicit query wins over the reading place.
              (should (equal "单词" (etaf-weread-lookup app "单词")))
              (should (equal "单词" (car queries)))
              ;; The top line follows the scroll; a narrower single column
              ;; makes the short fixture chapter long enough to scroll.
              (should (= 24 (etaf-weread-adjust-reading-measure app -20)))
              (should (= 1 (etaf-weread-toggle-reading-spread app)))
              (etaf-weread-scroll-pane app 2)
              (should (= 2 (plist-get (etaf-weread-state app) :pane-scroll)))
              (let ((query (etaf-weread-lookup app)))
                (should (member query
                                (mapcar (lambda (line) (plist-get line :text))
                                        (plist-get (etaf-weread-state app) :reader-lines))))
                (should-not (equal first query)))
              ;; A selected region wins over the reading place.
              (etaf-weread-scroll-pane app -2)
              (let ((line (seq-some (lambda (entry)
                                      (let ((text (string-trim
                                                   (or (plist-get entry :text) ""))))
                                        (unless (string-empty-p text) text)))
                                    (plist-get (etaf-weread-state app) :reader-lines))))
                (etaf-mount buffer (etaf-weread-view app)
                            (list :viewport-width 1200 :viewport-height 40))
                (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
                (with-current-buffer buffer
                  (transient-mark-mode 1)
                  (goto-char (point-min))
                  (search-forward line)
                  (set-mark (match-beginning 0))
                  (activate-mark))
                (should (equal line (etaf-weread-lookup app))))))
        (kill-buffer buffer)))))

(ert-deftest etaf-weread-tests-bookmarks-search-and-percent ()
  "Navigation inside a local book: bookmarks, in-book search and a percent jump.
A bookmark remembers a place and the same call removes it, search finds every
occurrence in reading order and lands on the chosen one, and a percentage moves
to the chapter and the position the progress bar promises."
  (setq etaf-weread-tests--requests nil)
  (etaf-weread-tests--with-local-books directory
    (let* ((file (make-temp-file "weread-nav-" nil ".eld"))
           (etaf-weread-tests--settings file)
           (etaf-weread-position-save-delay 0)
           (path (expand-file-name "long.txt" directory))
           (app (etaf-weread-tests--session)))
      (unwind-protect
          (progn
            (with-temp-file path
              (insert "第一章 长文\n")
              (dotimes (index 40)
                (insert (format "第%d段：习惯的起点很小，重复才是关键，这一段用来产生行数。\n\n"
                                index)))
              (insert "第二章 短章\n这一章很短，只用来验证章位。\n"))
            (etaf-weread-locate app :local)
            (etaf-weread-open-local-book app path)
            (should (= 24 (etaf-weread-adjust-reading-measure app -20)))
            ;; A bookmark at the current place, removable with the same call.
            (etaf-weread-scroll-pane app 4)
            (should (= 1 (length (etaf-weread-toggle-bookmark app))))
            (should (= 1 (length (plist-get (etaf-weread-state app) :bookmarks))))
            (etaf-weread-scroll-pane app 8)
            (should (= 2 (length (etaf-weread-toggle-bookmark app))))
            ;; Jumping back to the first bookmark restores its place, and the
            ;; same call there removes it again.
            (let ((first (car (last (plist-get (etaf-weread-state app) :bookmarks)))))
              (etaf-weread-show-bookmark app first)
              (should (= 4 (plist-get (etaf-weread-state app) :pane-scroll)))
              (should (= 1 (length (etaf-weread-toggle-bookmark app)))))
            ;; A percentage lands in the chapter the progress bar promises.
            (should (= 2 (etaf-weread-jump-to-percent app 75)))
            ;; Search finds every occurrence and lands on the chosen one.
            (let ((matches (etaf-weread-search-local-book app "重复才是关键")))
              (should (= 40 (length matches)))
              (should (= 0 (plist-get (car matches) :chapter)))
              (should (= 1 (etaf-weread-show-match app (car matches))))
              (should (< (plist-get (etaf-weread-state app) :pane-scroll) 4)))
            (should-error (etaf-weread-search-local-book app "   ")
                          :type 'etaf-weread-error))
        (ignore-errors (delete-file file))))))

(ert-deftest etaf-weread-tests-pane-keys-scroll-the-pane ()
  "SPC and M-v scroll a long detail pane from the keyboard.
The wheel scrolls the pane under the pointer; without keys a keyboard-only
reader cannot move a long table of contents at all."
  (setq etaf-weread-tests--requests nil
        etaf-weread-tests--extra-chapters
        (cl-loop for index from 3 to 24
                 collect (list :chapterIdx index
                               :title (format "第%d章" index)
                               :wordCount 100)))
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-scroll*")
        (app (etaf-weread-tests--session)))
    (unwind-protect
        (let ((buffer (etaf-weread-open app)))
          (etaf-weread-show-book app "1" 'detail)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (with-current-buffer buffer
            (should (= 0 (plist-get (etaf-weread-state app) :pane-scroll)))
            (execute-kbd-macro (kbd "SPC"))
            (should (> (plist-get (etaf-weread-state app) :pane-scroll) 0))
            (execute-kbd-macro (kbd "M-v"))
            (should (= 0 (plist-get (etaf-weread-state app) :pane-scroll)))))
      (setq etaf-weread-tests--extra-chapters nil)
      (when (get-buffer " *etaf-weread-tests-scroll*")
        (kill-buffer " *etaf-weread-tests-scroll*")))))

(ert-deftest etaf-weread-tests-replaced-keys-run-the-reader-command ()
  "The keys the renderer also binds run the reader command, not its scroll.
`n', `q' and the page keys are scroll or window bindings in the renderer's
minor-mode map, which shadows a major-mode map unless the reader overrides
them."
  (setq etaf-weread-tests--requests nil)
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-keys*")
        (app (etaf-weread-tests--session)))
    (unwind-protect
        (let ((buffer (etaf-weread-open app)))
          (with-current-buffer buffer
            (execute-kbd-macro (kbd "n"))
            (should (eq :notebook (plist-get (etaf-weread-state app) :section)))
            (execute-kbd-macro (kbd "<next>"))
            (should (> (plist-get (etaf-weread-state app) :selection) 0))
            (execute-kbd-macro (kbd "<prior>"))
            (should (= 0 (plist-get (etaf-weread-state app) :selection)))
            (execute-kbd-macro "q")
            (should-not (buffer-live-p buffer))))
      (when (get-buffer " *etaf-weread-tests-keys*")
        (kill-buffer " *etaf-weread-tests-keys*")))))

(ert-deftest etaf-weread-tests-open-fills-the-selected-window ()
  "Opening the reader replaces the selected window instead of splitting it.
A native text app owns the whole window it was opened from; a general
display rule must not turn it into a playground-style pane."
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-window*")
        (app (etaf-weread-tests--session))
        (frame (selected-frame))
        (width (frame-width))
        (height (frame-height)))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (set-frame-size frame 120 40)
          (let ((windows (length (window-list)))
                (selected (selected-window)))
            (unwind-protect
                (progn
                  (etaf-weread-open app)
                  (should (= (length (window-list)) windows))
                  (should (eq (selected-window) selected))
                  (should (eq (window-buffer selected)
                              (get-buffer etaf-weread-buffer-name))))
              (etaf-weread-close))))
      (set-frame-size frame width height)
      (when (get-buffer etaf-weread-buffer-name)
        (kill-buffer etaf-weread-buffer-name)))))

(ert-deftest etaf-weread-tests-open-and-close-own-a-buffer ()
  "Opening installs the reader keymap and closing kills the buffer."
  (setq etaf-weread-tests--requests nil)
  (let ((etaf-weread-buffer-name " *etaf-weread-tests-open*")
        (app (etaf-weread-tests--session)))
    (unwind-protect
        (let ((buffer (etaf-weread-open app)))
          (should (buffer-live-p buffer))
          (with-current-buffer buffer
            (should (eq (current-local-map) etaf-weread-mode-map))
            (should-not mode-line-format)
            (should (string-match-p "书1"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max)))))
          (etaf-weread-close)
          (should-not (get-buffer etaf-weread-buffer-name)))
      (when (get-buffer etaf-weread-buffer-name)
        (kill-buffer etaf-weread-buffer-name)))))

(ert-deftest etaf-weread-tests-default-client-runs-the-skill-script ()
  "The default client passes the documented arguments to the skill script."
  (let* ((directory (make-temp-file "etaf-weread-skill-" t))
         (scripts (expand-file-name "scripts" directory))
         (script (expand-file-name "weread.mjs" scripts))
         (log (expand-file-name "calls.log" directory))
         (out (expand-file-name "export" directory))
         (reply nil))
    (unwind-protect
        (progn
          (make-directory scripts t)
          (with-temp-file script
            (insert "import fs from 'node:fs';\n"
                    "fs.appendFileSync(process.env.WEREAD_TEST_LOG, process.argv.slice(2).join(' ') + '\\n');\n"
                    "console.log(JSON.stringify({ok: true}));\n"))
          (let* ((process-environment
                  (cons (concat "WEREAD_TEST_LOG=" log) process-environment))
                 (etaf-weread-export-directory out)
                 (client (etaf-weread-make-client :skill-directory directory :timeout 10)))
            (etaf-weread-client-call
             client (list :op :shelf :filter "reading" :limit 20)
             (lambda (result) (setq reply result)))
            (should (etaf-weread-tests--wait (lambda () reply)))
            (should (eq (car-safe reply) :ok))
            (setq reply nil)
            (etaf-weread-client-call
             client (list :op :export :id "42")
             (lambda (result) (setq reply result)))
            (should (etaf-weread-tests--wait (lambda () reply)))
            (should (eq (car-safe reply) :ok))
            (with-temp-buffer
              (insert-file-contents log)
              (let ((lines (split-string (buffer-string) "\n" t)))
                (should (equal (nth 0 lines)
                               "shelf --filter reading --limit 20 --json --quiet"))
                (should (equal (nth 1 lines)
                               (format "export 42 --yes --json --quiet --out %s" out)))))))
      (delete-directory directory t))))

(ert-deftest etaf-weread-tests-skill-refusal-reports-its-own-message ()
  "A refused skill command reports the backend's own message.
The weread skill answers a failure with a JSON object on stdout and a non-zero
exit, and the exit event can arrive before that output; the reader must drain
the pipes before reading them.  A crash without JSON keeps the exit status."
  (let* ((directory (make-temp-file "etaf-weread-refusal-skill-" t))
         (scripts (expand-file-name "scripts" directory))
         (script (expand-file-name "weread.mjs" scripts)))
    (unwind-protect
        (progn
          (make-directory scripts t)
          (with-temp-file script
            (insert "if (process.argv[2] === 'shelf') {\n"
                    "  console.log(JSON.stringify({ ok: false, error: 'auth', message: '还没有微信读书登录态', hint: 'pi-skill weread login（打开受控浏览器扫码）' }));\n"
                    "  process.exit(3);\n"
                    "}\n"
                    "console.error('boom');\n"
                    "process.exit(1);\n"))
          (let* ((client (etaf-weread-make-client :skill-directory directory :timeout 10))
                 (ask (lambda (request)
                        (let (reply)
                          (etaf-weread-client-call
                           client request (lambda (result) (setq reply result)))
                          (should (etaf-weread-tests--wait (lambda () reply)))
                          reply))))
            (let ((refusal (funcall ask (list :op :shelf :filter "reading" :limit 20))))
              (should (eq (car-safe refusal) :error))
              (should (equal (cadr refusal) "还没有微信读书登录态"))
              (should (equal (plist-get (cddr refusal) :code) "auth"))
              (should (equal (plist-get (cddr refusal) :hint)
                             "pi-skill weread login（打开受控浏览器扫码）")))
            (let ((crash (funcall ask (list :op :status))))
              (should (eq (car-safe crash) :error))
              (should (string-prefix-p "Backend command failed" (cadr crash)))
              (should (equal (plist-get (cddr crash) :hint) "boom")))))
      (delete-directory directory t))))

(provide 'etaf-weread-tests)
;;; etaf-weread-tests.el ends here
