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
                     (:export (list :ok t :conclusion "已导出笔记"))))))) 

(defun etaf-weread-tests--session (&optional client)
  "Return a reader session driven by the scripted CLIENT."
  (etaf-weread-create :client (or client #'etaf-weread-tests--client)))

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

(provide 'etaf-weread-tests)
;;; etaf-weread-tests.el ends here
