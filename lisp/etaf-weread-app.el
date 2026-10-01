;;; etaf-weread-app.el --- Application shell of the WeChat Reading client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer binds one reader model to the Views.  `etaf-weread-app'
;; is the only place that reads the model's reactive sources, so a backend reply
;; or a key press repaints the whole reader in one place, and it owns the
;; session lifecycle: the palette is provided for its subtree, the current
;; section loads on mount, and the session's timers and in-flight requests are
;; released on unmount.
;;
;; `etaf-weread-open' adds what a Component cannot own by itself: the buffer
;; name, the buffer-local keymap, and the window-fitting page size.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-weread-theme)
(require 'etaf-weread-service)
(require 'etaf-weread-model)
(require 'etaf-weread-views)

;;; ---------------------------------------------------------------------------
;;; Buffer state and keymap
;;; ---------------------------------------------------------------------------

(defcustom etaf-weread-buffer-name "*ETAF 微信读书*"
  "Buffer opened by `etaf-weread-open'."
  :type 'string
  :group 'etaf-weread)

(defvar-local etaf-weread--model nil
  "Reader model shown by the current buffer's runtime.")

(defvar etaf-weread-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "j") #'etaf-weread--next-item)
    (define-key map (kbd "k") #'etaf-weread--previous-item)
    (define-key map (kbd "C-n") #'etaf-weread--next-item)
    (define-key map (kbd "C-p") #'etaf-weread--previous-item)
    (define-key map (kbd "<down>") #'etaf-weread--next-item)
    (define-key map (kbd "<up>") #'etaf-weread--previous-item)
    ;; The event position chooses between the book list and the side pane.
    (define-key map (kbd "<wheel-up>") #'etaf-weread--wheel-up)
    (define-key map (kbd "<wheel-down>") #'etaf-weread--wheel-down)
    (define-key map (kbd "<home>") #'etaf-weread--first-item)
    (define-key map (kbd "<end>") #'etaf-weread--last-item)
    (define-key map (kbd "<next>") #'etaf-weread--next-page)
    (define-key map (kbd "<prior>") #'etaf-weread--previous-page)
    (define-key map (kbd "RET") #'etaf-weread--activate)
    (define-key map (kbd "C-v") #'etaf-weread--scroll-pane-down)
    (define-key map (kbd "M-v") #'etaf-weread--scroll-pane-up)
    (define-key map (kbd "SPC") #'etaf-weread--scroll-pane-down)
    (define-key map (kbd "S-SPC") #'etaf-weread--scroll-pane-up)
    (define-key map (kbd "v") #'etaf-weread--toggle-pane)
    (define-key map (kbd "d") #'etaf-weread--detail-pane)
    (define-key map (kbd "P") #'etaf-weread--notes-pane)
    (define-key map (kbd "o") #'etaf-weread--open-book)
    (define-key map (kbd "E") #'etaf-weread--export-notes)
    (define-key map (kbd "s") #'etaf-weread--shelf)
    (define-key map (kbd "n") #'etaf-weread--notebook)
    (define-key map (kbd "i") #'etaf-weread--index-section)
    (define-key map (kbd "I") #'etaf-weread--build-index)
    (define-key map (kbd "t") #'etaf-weread--stats)
    (define-key map (kbd "/") #'etaf-weread--search)
    (define-key map (kbd "S") #'etaf-weread--search)
    (define-key map (kbd "1") #'etaf-weread--shelf)
    (define-key map (kbd "2") #'etaf-weread--reading)
    (define-key map (kbd "3") #'etaf-weread--finished)
    (define-key map (kbd "4") #'etaf-weread--notebook)
    (define-key map (kbd "5") #'etaf-weread--search)
    (define-key map (kbd "6") #'etaf-weread--stats)
    (define-key map (kbd "7") #'etaf-weread--index-section)
    (define-key map (kbd "g") #'etaf-weread--refresh)
    (define-key map (kbd "T") #'etaf-weread--toggle-theme)
    (define-key map (kbd "?") #'etaf-weread--help)
    (define-key map (kbd "q") #'etaf-weread-close)
    map)
  "Keymap of the buffer opened by `etaf-weread-open'.
It keeps Ebox's TAB focus cycling and RET activation, and replaces the
scrolling keys with reader commands: j/k move the selection, v switches the
side pane, and o opens the selected book in the browser.")

(defvar etaf-weread--command-maps
  (list (cons 'etaf-weread--model
              (let ((map (make-sparse-keymap)))
                (define-key map [wheel-up] #'etaf-weread--wheel-up)
                (define-key map [wheel-down] #'etaf-weread--wheel-down)
                ;; These four are scroll or window keys in the renderer's own
                ;; minor-mode map, which wins over a major-mode map.  The reader
                ;; replaces them, so it owns them here where it can win; the
                ;; mode map keeps the documented bindings for a buffer that was
                ;; never opened.
                (define-key map (kbd "n") #'etaf-weread--notebook)
                (define-key map (kbd "q") #'etaf-weread-close)
                (define-key map (kbd "<next>") #'etaf-weread--next-page)
                (define-key map (kbd "<prior>") #'etaf-weread--previous-page)
                ;; The renderer binds these to its own canvas scroll, which a
                ;; reader that owns its canvas never uses.
                (define-key map (kbd "C-v") #'etaf-weread--scroll-pane-down)
                (define-key map (kbd "M-v") #'etaf-weread--scroll-pane-up)
                (define-key map (kbd "SPC") #'etaf-weread--scroll-pane-down)
                (define-key map (kbd "S-SPC") #'etaf-weread--scroll-pane-up)
                ;; RET stays the renderer's activation for a focused control and
                ;; falls back to the selection, so `j/k RET' opens the book the
                ;; manual documents.
                (define-key map (kbd "RET") #'etaf-weread--activate)
                map)))
  "Reader bindings that must beat the renderer's own minor-mode map.
`emulation-mode-map-alists' entries take precedence over every minor mode, so
this alist lets the reader replace renderer scroll keys (`n', `q' and the page
keys) instead of having them silently shadowed.  The alist is enabled only in
an opened reader buffer.")

(defun etaf-weread--current-model ()
  "Return the model of the current reader buffer."
  (or etaf-weread--model
      (user-error "Current buffer is not an etaf-weread reader")))

;;; ---------------------------------------------------------------------------
;;; Model to View projections
;;; ---------------------------------------------------------------------------

(defun etaf-weread--view-entries (model)
  "Return MODEL's visible book rows as list entries."
  (pcase-let* ((`(,rows ,start ,_total) (etaf-weread--page-rows model))
               (selection (etaf-weread--read model :selection)))
    (cl-loop for row in rows
             for index from start
             collect (list :index (1+ index)
                           :row row
                           :selected (= index selection)))))

(defun etaf-weread--pane-chapters (model)
  "Return the visible chapter lines of MODEL's detail pane."
  (let* ((detail (etaf-weread--read model :detail))
         (chapters (plist-get detail :chapters))
         (rows (max 1 (etaf-weread--read model :pane-rows)))
         (scroll (max 0 (min (etaf-weread--read model :pane-scroll)
                             (max 0 (- (length chapters) rows))))))
    (when chapters
      (seq-subseq chapters scroll (min (length chapters) (+ scroll rows))))))

(defun etaf-weread--pane-lines (model)
  "Return the visible lines of MODEL's highlight pane."
  (let* ((notes (etaf-weread--read model :notes))
         (lines (etaf-weread--notes-lines (plist-get notes :groups)))
         (rows (max 1 (etaf-weread--read model :pane-rows)))
         (scroll (max 0 (min (etaf-weread--read model :pane-scroll)
                             (max 0 (- (length lines) rows))))))
    (when lines
      (seq-subseq lines scroll (min (length lines) (+ scroll rows))))))

(defun etaf-weread--search-text (model text)
  "Search TEXT in MODEL, reporting an empty keyword in the status line.
In the local index section TEXT filters the highlights instead of the store,
which is why the same field serves both places."
  (if (eq (etaf-weread--read model :mode) 'index)
      (progn
        (etaf-weread--write model :index-query (or text ""))
        (etaf-weread--index-reload model))
    (etaf-weread--write model :query (or text ""))
    (if (string-empty-p (string-trim (or text "")))
        (etaf-weread--write model :message "输入关键词后开始搜索")
      (condition-case error
          (etaf-weread-search model text)
        (etaf-weread-error (etaf-weread--write model :message (error-message-string error)))))))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(defun etaf-weread--next-item ()
  "Move the book selection down."
  (interactive)
  (etaf-weread-move-selection (etaf-weread--current-model) 1))

(defun etaf-weread--previous-item ()
  "Move the book selection up."
  (interactive)
  (etaf-weread-move-selection (etaf-weread--current-model) -1))

(defun etaf-weread--pane-hit-p (xy columns _rows layout pane)
  "Return non-nil when text-cell position XY hits the visible side pane.
COLUMNS describes the event window; LAYOUT and PANE describe the reader."
  (and (memq pane '(detail notes))
       (consp xy) (numberp (car xy)) (numberp (cdr xy))
       (< 0 (cdr xy))
       (if (eq layout 'wide)
           (and (> (car xy) (max 0 (- columns (cadr etaf-weread--pane-width))))
                (< (car xy) columns))
         t)))

(defun etaf-weread--wheel (event delta)
  "Scroll the side pane or move the book selection by DELTA at EVENT's position."
  (let* ((position (event-start event))
         (window (posn-window position)))
    (when (window-live-p window)
      (with-current-buffer (window-buffer window)
        (let* ((model (etaf-weread--current-model))
               (pixels (posn-x-y position))
               (xy (and (consp pixels)
                        (cons (/ (float (car pixels)) (window-font-width window))
                              (/ (float (cdr pixels)) (window-font-height window))))))
          (if (and (null (posn-area position))
                   (etaf-weread--pane-hit-p
                    xy (window-body-width window) (window-body-height window)
                    (etaf-weread--read model :layout) (etaf-weread--read model :pane)))
              (etaf-weread-scroll-pane model delta)
            (etaf-weread-move-selection model delta)))))))

(defun etaf-weread--wheel-up (event)
  "Scroll the side pane or select the previous book at EVENT."
  (interactive "e")
  (etaf-weread--wheel event -1))

(defun etaf-weread--wheel-down (event)
  "Scroll the side pane or select the next book at EVENT."
  (interactive "e")
  (etaf-weread--wheel event 1))

(defun etaf-weread--first-item ()
  "Select the first book of the list."
  (interactive)
  (let* ((model (etaf-weread--current-model))
         (state (etaf-weread-state model)))
    (etaf-weread-move-selection model (- (plist-get state :selection)))))

(defun etaf-weread--last-item ()
  "Select the last book of the list."
  (interactive)
  (let* ((model (etaf-weread--current-model))
         (state (etaf-weread-state model)))
    (etaf-weread-move-selection model (- (1- (or (plist-get state :rows-total) 1))
                                         (plist-get state :selection)))))

(defun etaf-weread--next-page ()
  "Select one page further down the book list."
  (interactive)
  (let* ((model (etaf-weread--current-model))
         (state (etaf-weread-state model)))
    (etaf-weread-move-selection model (or (plist-get state :page-size) 10))))

(defun etaf-weread--previous-page ()
  "Select one page further up the book list."
  (interactive)
  (let* ((model (etaf-weread--current-model))
         (state (etaf-weread-state model)))
    (etaf-weread-move-selection model (- (or (plist-get state :page-size) 10)))))

(defun etaf-weread--activate ()
  "Open the Host at point, or the selected book's detail or highlights.
A click or TAB leaves its Host under point and the renderer activates it;
moving the selection with j/k leaves point where it was, and the reader then
opens the book the selection points at."
  (interactive)
  (condition-case nil
      (etaf-activate)
    (user-error
     (etaf-weread-activate-selection (etaf-weread--current-model)))))

(defun etaf-weread--scroll-pane-down ()
  "Scroll the side pane one page down.
The wheel scrolls the pane under the pointer; these keys give the same
ability to a keyboard, which otherwise cannot move a long table of contents
or highlight list."
  (interactive)
  (let* ((model (etaf-weread--current-model))
         (state (etaf-weread-state model)))
    (etaf-weread-scroll-pane model (max 1 (or (plist-get state :pane-rows) 10)))))

(defun etaf-weread--scroll-pane-up ()
  "Scroll the side pane one page up."
  (interactive)
  (let* ((model (etaf-weread--current-model))
         (state (etaf-weread-state model)))
    (etaf-weread-scroll-pane model (- (max 1 (or (plist-get state :pane-rows) 10))))))

(defun etaf-weread--toggle-pane ()
  "Switch the side pane between the book detail and its highlights."
  (interactive)
  (let* ((model (etaf-weread--current-model))
         (pane (etaf-weread--read model :pane)))
    (if (eq pane 'list)
        (progn
          (etaf-weread--write model :pane 'detail)
          (etaf-weread--schedule-detail model (etaf-weread--selected-id model)))
      (etaf-weread-toggle-pane model))))

(defun etaf-weread--detail-pane ()
  "Show the book detail pane."
  (interactive)
  (etaf-weread-show-pane (etaf-weread--current-model) 'detail))

(defun etaf-weread--notes-pane ()
  "Show the highlights pane of the selected book."
  (interactive)
  (let ((model (etaf-weread--current-model)))
    (etaf-weread-show-book model (etaf-weread--selected-row model) 'notes)))

(defun etaf-weread--open-book ()
  "Open the selected book in the browser's WeChat Reading reader."
  (interactive)
  (condition-case error
      (etaf-weread-open-book (etaf-weread--current-model))
    (etaf-weread-error (message "%s" (error-message-string error)))))

(defun etaf-weread--export-notes ()
  "Export the selected book's highlights and thoughts as Markdown."
  (interactive)
  (condition-case error
      (etaf-weread-export-notes (etaf-weread--current-model))
    (etaf-weread-error (message "%s" (error-message-string error)))))

(defun etaf-weread--shelf ()
  "Show the whole shelf."
  (interactive)
  (etaf-weread-locate (etaf-weread--current-model) :shelf))

(defun etaf-weread--reading ()
  "Show the books currently being read."
  (interactive)
  (etaf-weread-locate (etaf-weread--current-model) :reading))

(defun etaf-weread--finished ()
  "Show the finished books."
  (interactive)
  (etaf-weread-locate (etaf-weread--current-model) :finished))

(defun etaf-weread--notebook ()
  "Show the books with highlights and thoughts."
  (interactive)
  (etaf-weread-locate (etaf-weread--current-model) :notebook))

(defun etaf-weread--index-section ()
  "Show the local SQLite index of highlights."
  (interactive)
  (etaf-weread-locate (etaf-weread--current-model) :index))

(defun etaf-weread--build-index (&optional refresh)
  "Index the notebook's highlights into the local SQLite index.
With prefix argument REFRESH, re-fetch books that are already indexed."
  (interactive "P")
  (etaf-weread-index-notebook (etaf-weread--current-model) refresh))

(defun etaf-weread--stats ()
  "Show the reading statistics."
  (interactive)
  (etaf-weread-locate (etaf-weread--current-model) :stats))

(defun etaf-weread--search ()
  "Ask for a keyword and search the WeChat Reading store."
  (interactive)
  (etaf-weread--search-text (etaf-weread--current-model)
                            (read-string "搜索书名或作者：")))

(defun etaf-weread--refresh ()
  "Reload the current list, account and statistics."
  (interactive)
  (etaf-weread-refresh (etaf-weread--current-model)))

(defun etaf-weread--toggle-theme ()
  "Switch the reader between the dark and light palette."
  (interactive)
  (let ((model (etaf-weread--current-model)))
    (setq etaf-weread-theme-mode (if (eq etaf-weread-theme-mode 'dark) 'light 'dark))
    (etaf-weread--write model :theme (etaf-weread-theme-defaults etaf-weread-theme-mode))
    (etaf-weread--write model :message
                        (format "外观：%s" (if (eq etaf-weread-theme-mode 'dark)
                                              "深色"
                                            "浅色")))
    (when-let* ((buffer (plist-get model :buffer)))
      (with-current-buffer buffer (etaf-weread--remap-canvas-face)))))

(defun etaf-weread--remap-canvas-face ()
  "Paint this buffer's unpainted cells with the palette background.
Ebox paints whole character cells, so a window body that is not a whole number
of cells keeps a sub-cell remainder at its right or bottom edge.  Remapping the
default face shows the reader background there instead of the frame's."
  (face-remap-set-base 'default (list :background (etaf-weread-color :bg))))

(defun etaf-weread--help ()
  "Show the reader's key bindings."
  (interactive)
  (message
   (concat "j/k 或滚轮选择 · 单击选中 · 双击/RET 打开 · v 详情/笔记 · o 浏览器阅读"
           " · E 导出笔记 · C-v/M-v 或 SPC 滚动目录/划下面板 · s 书架"
           " · 1/2/3 全部/在读/读完 · n 笔记本"
           " · i 笔记检索 · I 建立本地索引 · t 统计 · / 搜索 · g 刷新"
           " · T 深浅色 · q 关闭")))

;;; ---------------------------------------------------------------------------
;;; Application Component and entry points
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-weread-app (&key model)
  "Render the reader for MODEL and own its session lifecycle.
MODEL must come from `etaf-weread-create'.  Mounting provides the palette for
the subtree, fits the layout and loads the current section; unmounting releases
the session's timers and pending backend requests."
  :bindings ((session (or model
                          (signal 'etaf-weread-error
                                  '("etaf-weread-app needs the :model from `etaf-weread-create'"))))
             (palette (etaf-weread--ref session :theme))
             ;; Callbacks are instance values, not per-render closures: a
             ;; re-render that passes a new function object to a keyed child
             ;; would make that child render again for nothing.
             (on-locate (lambda (section) (etaf-weread-locate session section)))
             (on-search (lambda (text) (etaf-weread--search-text session text)))
             (on-refresh (lambda () (etaf-weread-refresh session)))
             (on-press-row (lambda (index) (etaf-weread-press-row session index)))
             (on-open-book (lambda () (etaf-weread--open-book-in session)))
             (on-export-notes (lambda () (etaf-weread--export-in session)))
             (on-pane (lambda (target)
                        (if (eq target 'list)
                            (etaf-weread--write session :pane 'list)
                          (etaf-weread-show-pane session target)))))
  :setup
  (progn
    (etaf-theme-provide palette)
    (etaf-on-mounted
     (lambda ()
       (etaf-weread--start session)
       (etaf-weread-refresh session)))
    (etaf-on-unmounted
     (lambda ()
       (etaf-weread--dispose session))))
  :view
  (flex :flex-direction 'column :width '(vw 100) :height '(vh 100)
        ;; Rows that show symbol glyphs render a little taller than the frame's
        ;; line height because their fallback font has larger metrics.  Keep the
        ;; last line clear so those extra pixels land in empty space.
        :padding-bottom '(lh 1)
        :color (etaf-weread-color :ink) :bgcolor (etaf-weread-color :bg)
    (flex :width 'stretch :flex-grow 1 :flex-basis 'auto :min-height '(lh 0)
          :align-items 'stretch
      (etaf-weread--view-sidebar
       :if (eq (etaf-weread--read session :layout) 'wide)
       :groups etaf-weread-sections
       :section (etaf-weread--read session :section)
       :on-locate on-locate)
      (etaf-weread--view-sidebar
       :if (eq (etaf-weread--read session :layout) 'medium)
       :compact t
       :groups etaf-weread-sections
       :section (etaf-weread--read session :section)
       :on-locate on-locate)
      (flex :if (etaf-weread--list-shown-p session)
            :flex-direction 'column :width 'stretch :flex-grow 1
            :flex-basis 'auto :min-width '(ch 0) :min-height '(lh 0)
            :padding (if (etaf-weread--compact-layout-p session)
                         '((lh 0) (ch 1)) '((lh 1) (ch 2)))
            :gap '((lh 1) (px 0))
        (etaf-weread--view-header
         :title (etaf-weread--read session :title)
         :subtitle (etaf-weread--read session :subtitle)
         :query (etaf-weread--read session
                                  (if (eq (etaf-weread--read session :mode) 'index)
                                      :index-query
                                    :query))
         :placeholder (if (eq (etaf-weread--read session :mode) 'index)
                          "搜索本地笔记"
                        "搜索书名或作者")
         :mode (etaf-weread--read session :mode)
         :loading (etaf-weread--read session :loading)
         :compact (etaf-weread--compact-layout-p session)
         :on-search on-search
         :on-refresh on-refresh)
        (etaf-weread--view-chips
         :if (eq (etaf-weread--read session :layout) 'narrow)
         :groups etaf-weread-sections
         :section (etaf-weread--read session :section)
         :on-locate on-locate)
        (etaf-weread--view-list
         :entries (etaf-weread--view-entries session)
         :start (1+ (nth 1 (etaf-weread--page-rows session)))
         :total (etaf-weread--read session :list-total)
         :loaded (length (etaf-weread--read session :rows))
         :compact (etaf-weread--compact-layout-p session)
         :loading (etaf-weread--read session :loading)
         :empty-note (cond ((etaf-weread--read session :loading) "正在加载…")
                           ((eq (etaf-weread--read session :mode) 'index)
                            "本地索引为空：按 I 索引笔记本，或先翻几本书的笔记")
                           ((eq (etaf-weread--read session :mode) 'search)
                            "输入关键词后开始搜索")
                           (t "这里还没有内容：g 刷新"))
         :on-press on-press-row))
      (flex :if (etaf-weread--pane-shown-p session)
            :flex-direction 'column :width etaf-weread--pane-width
            :flex-grow (if (etaf-weread--compact-layout-p session) 1 0)
            :flex-shrink 0
            :flex-basis 'auto
            :min-width '(ch 0) :min-height '(lh 0)
            :background-color (etaf-weread-color :panel)
            :border-left (etaf-weread--view-border 'left (etaf-weread-color :line))
        (etaf-weread--view-stats
         :if (eq (etaf-weread--read session :mode) 'stats)
         :stats (etaf-weread--read session :stats))
        (etaf-weread--view-detail
         :if (and (not (eq (etaf-weread--read session :mode) 'stats))
                  (eq (etaf-weread--effective-pane session) 'detail))
         :detail (etaf-weread--read session :detail)
         :pane (etaf-weread--effective-pane session)
         :chapters (etaf-weread--pane-chapters session)
         :on-open on-open-book
         :on-export on-export-notes
         :on-pane on-pane)
        (etaf-weread--view-notes
         :if (and (not (eq (etaf-weread--read session :mode) 'stats))
                  (eq (etaf-weread--effective-pane session) 'notes))
         :notes (etaf-weread--read session :notes)
         :pane (etaf-weread--effective-pane session)
         :lines (etaf-weread--pane-lines session)
         :on-pane on-pane
         :on-open on-open-book)))
    (etaf-weread--view-tabs
     :if (etaf-weread--compact-layout-p session)
     :pane (etaf-weread--read session :pane)
     :layout (etaf-weread--read session :layout)
     :on-pane on-pane)
    (etaf-weread--view-footer
     :account (etaf-weread--read session :account)
     :summary (etaf-weread--read session :summary)
     :message (etaf-weread--read session :message)
     :error (etaf-weread--read session :error)
     :compact (etaf-weread--compact-layout-p session))))

(defun etaf-weread--open-book-in (app)
  "Open APP's selected book in the browser, reporting a failure in the status line."
  (condition-case error
      (etaf-weread-open-book app)
    (etaf-weread-error (etaf-weread--write app :message (error-message-string error)))))

(defun etaf-weread--export-in (app)
  "Export APP's selected book, reporting a failure in the status line."
  (condition-case error
      (etaf-weread-export-notes app)
    (etaf-weread-error (etaf-weread--write app :message (error-message-string error)))))

(defun etaf-weread-view (&optional model)
  "Return the reader View for MODEL.
MODEL defaults to a new session, exactly as `etaf-weread-open' creates one;
pass a session from `etaf-weread-create' to embed the reader in your own mount."
  (etaf-view (etaf-weread-app :model (or model (etaf-weread-create)))))

(defun etaf-weread-open (&optional model)
  "Open the WeChat Reading reader and return its buffer.
MODEL defaults to a session from `etaf-weread-create', so the reader opens on
the shelf with the signed-in account.  A caller-provided MODEL keeps its
section, selection and loaded detail."
  (interactive)
  (let* ((model (or model (etaf-weread-create)))
         (buffer (get-buffer-create etaf-weread-buffer-name)))
    (plist-put model :buffer buffer)
    (with-current-buffer buffer
      (setq-local etaf-weread--model model)
      (setq-local truncate-lines t)
      (setq-local mode-line-format nil)
      (setq-local emulation-mode-map-alists
                  (cons 'etaf-weread--command-maps
                        (remq 'etaf-weread--command-maps emulation-mode-map-alists)))
      ;; The reader owns every column it paints.  A sub-cell rounding
      ;; remainder must not surface as Emacs's truncation glyph, so keep the
      ;; truncation slot blank instead of advertising a cut line.
      (setq-local buffer-display-table
                  (let ((table (copy-sequence (or standard-display-table
                                                  (make-display-table)))))
                    (set-display-table-slot table 'truncation ?\s)
                    table))
      (etaf-weread--remap-canvas-face)
      (use-local-map etaf-weread-mode-map))
    (pop-to-buffer buffer)
    ;; The layout, page size and viewport come from the window that shows the
    ;; reader, so the first paint already fits it.  The reader adapts to later
    ;; resizes as well (see `etaf-weread--sync-layout').
    (etaf-weread--sync-layout model (selected-window))
    (etaf-mount buffer (etaf-weread-view model)
                (etaf-weread--viewport-options (selected-window)))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    buffer))

(defun etaf-weread-close ()
  "Unmount the reader and kill its buffer."
  (interactive)
  (when-let* ((runtime (etaf-runtime-for-buffer etaf-weread-buffer-name)))
    (etaf-unmount runtime))
  (when-let* ((buffer (get-buffer etaf-weread-buffer-name)))
    (kill-buffer buffer)))

(provide 'etaf-weread-app)
;;; etaf-weread-app.el ends here
