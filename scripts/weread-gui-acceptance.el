;;; weread-gui-acceptance.el --- Real-account GUI acceptance pass -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The maintenance probe checks layout invariants in one state; this file
;; drives the reader through every affordance the manual documents, against
;; the real account and a real frame, and records one line per step plus the
;; measured cost of the interactions that matter.  Run it in a fresh
;; `pi-skill eac instance open' instance:
;;
;;   (load "scripts/weread-gui-acceptance.el")
;;   (etaf-weread-gui-acceptance-run)     ; returns (PLIST :problems …)
;;
;; Everything goes through the real keymap (`execute-kbd-macro'); only the two
;; prompt readers and `browse-url' are replaced with deterministic answers,
;; because a scheduled run must not wait for a human, and the session writes
;; its preferences to a disposable file instead of the user's.  Each step is
;; appended to `etaf-weread-gui-acceptance-log-file' while the pass runs, so a
;; timeout still leaves the evidence behind.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'etaf-weread)

(defvar etaf-weread-gui--model)

(declare-function etaf-weread-gui-open "weread-gui-probe" (&optional size))
(declare-function etaf-weread-gui--flush "weread-gui-probe" ())
(declare-function etaf-weread-gui-check "weread-gui-probe" ())

(load (expand-file-name "weread-gui-probe.el"
                        (file-name-directory (or load-file-name
                                                 (bound-and-true-p byte-compile-current-file)
                                                 buffer-file-name)))
      nil t)

(defvar etaf-weread-gui-acceptance-log-file "/tmp/weread-acceptance.log"
  "File the acceptance pass appends every step and measurement to.")

(defvar etaf-weread-gui-acceptance--problems nil
  "Failures the current pass collected, newest first.")

(defvar etaf-weread-gui-acceptance--latencies nil
  "Measured interaction costs of the current pass, as (LABEL . MS).")

(defvar etaf-weread-gui-acceptance--steps 0
  "Number of checks the current pass ran.")

(defvar etaf-weread-gui-acceptance--settings nil
  "Disposable settings file the acceptance session uses.")

(defun etaf-weread-gui-acceptance--log (fmt &rest args)
  "Append one timestamped line to the acceptance log; return it."
  (let ((line (format "%s %s" (format-time-string "%H:%M:%S") (apply #'format fmt args))))
    (write-region (concat line "\n") nil etaf-weread-gui-acceptance-log-file 'append)
    line))

(defun etaf-weread-gui-acceptance--check (step ok &optional detail)
  "Record STEP as passed or failed, with DETAIL on failure."
  (cl-incf etaf-weread-gui-acceptance--steps)
  (if ok
      (etaf-weread-gui-acceptance--log "ok   %s" step)
    (push (format "%s%s" step (if detail (format " — %s" detail) ""))
          etaf-weread-gui-acceptance--problems)
    (etaf-weread-gui-acceptance--log "FAIL %s%s" step
                                     (if detail (format " — %s" detail) ""))))

(defun etaf-weread-gui-acceptance--state ()
  "Return the acceptance session's detached state."
  (etaf-weread-state etaf-weread-gui--model))

(defun etaf-weread-gui-acceptance--wait (predicate &optional seconds)
  "Wait until PREDICATE holds or SECONDS pass; return its last value."
  (let ((deadline (+ (float-time) (or seconds 20))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (sit-for 0.1))
    (funcall predicate)))

(defmacro etaf-weread-gui-acceptance--timed (label &rest body)
  "Run BODY and record how long it took under LABEL."
  (declare (indent 1))
  `(let ((started (float-time)))
     (prog1 (progn ,@body)
       (push (cons ,label (round (* 1000 (- (float-time) started))))
             etaf-weread-gui-acceptance--latencies))))

(defun etaf-weread-gui-acceptance--keys (keys &optional wait)
  "Send KEYS through the real command loop and apply the renderer's updates.
WAIT is the quiet time after the keys, default 0.15 seconds.  A key that
closes the reader (`q') leaves nothing to flush, so the flush is skipped."
  (when-let* ((buffer (get-buffer etaf-weread-buffer-name)))
    (with-current-buffer buffer
      (execute-kbd-macro (kbd keys))))
  (sit-for (or wait 0.15))
  (when (get-buffer etaf-weread-buffer-name)
    (etaf-weread-gui--flush)))

(defmacro etaf-weread-gui-acceptance--step (label &rest body)
  "Run BODY as one named step; a signaled error fails LABEL but not the pass."
  (declare (indent 1))
  `(condition-case error
       (progn ,@body)
     (error (etaf-weread-gui-acceptance--check ,label nil (error-message-string error)))))

(defun etaf-weread-gui-acceptance--row-index (predicate)
  "Return the index of the first loaded row matching PREDICATE, or nil."
  (cl-position-if predicate (plist-get (etaf-weread-gui-acceptance--state) :items)))

(defun etaf-weread-gui-acceptance--select-row (predicate what)
  "Move the selection to the first row matching PREDICATE and report WHAT."
  (let ((index (etaf-weread-gui-acceptance--row-index predicate)))
    (if (null index)
        (etaf-weread-gui-acceptance--check (format "select %s" what) nil "row not in the list")
      (etaf-weread-gui-acceptance--keys (make-string (max 0 index) ?j) 0.2)
      (etaf-weread-gui-acceptance--check
       (format "select %s" what)
       (= index (plist-get (etaf-weread-gui-acceptance--state) :selection))
       (format "selection=%s expected=%s" (plist-get (etaf-weread-gui-acceptance--state) :selection) index))
      index)))

(defun etaf-weread-gui-acceptance--prompt-stub (answer)
  "Return a `read-string' replacement that always gives ANSWER."
  (lambda (&rest _) answer))

(defun etaf-weread-gui-acceptance--first-choice ()
  "Return a `completing-read' replacement choosing the first candidate."
  (lambda (_prompt collection &rest _)
    (let ((first (car collection)))
      (if (consp first) (car first) first))))

(defun etaf-weread-gui-acceptance--layout-matrix ()
  "Resize the frame through every layout and check each canvas.
The check waits for the model to adopt the new layout: a long chapter is
rewrapped at the new width first, and checking before that reads the old
canvas."
  (dolist (size '((150 . 40) (100 . 28) (60 . 20)))
    (set-frame-size (selected-frame) (car size) (cdr size))
    (let ((expected (etaf-weread--layout-for (car size))))
      (etaf-weread-gui-acceptance--wait
       (lambda ()
         (eq expected
             (plist-get (etaf-weread-gui-acceptance--state) :layout)))
       8)
      (sit-for 0.4))
    (etaf-weread-gui--flush)
    (etaf-weread-gui-acceptance--check
     (format "layout %sx%s" (car size) (cdr size))
     (null (etaf-weread-gui-check))
     (format "%S" (etaf-weread-gui-check))))
  (set-frame-size (selected-frame) 150 40)
  (sit-for 1.5))

(defun etaf-weread-gui-acceptance--stall (label seconds keys)
  "Send KEYS for SECONDS under a 50ms timer and record timer lateness.
The timer measures how late a fixed 50 ms schedule runs while the reader
repaints, which is what a person feels as jank."
  (let ((samples nil)
        (index 0)
        (started (float-time))
        (timer nil)
        (final nil))
    (setq timer (run-at-time 0.05 0.05
                             (lambda ()
                               (let ((late (- (float-time)
                                              (+ started (* (cl-incf index) 0.05)))))
                                 (push late samples)))))
    (unwind-protect
        (let ((deadline (+ (float-time) seconds)))
          (while (< (float-time) deadline)
            (etaf-weread-gui-acceptance--keys keys 0.2)))
      (cancel-timer timer))
    (setq final (list :samples (length samples)
                      :max-ms (round (* 1000 (apply #'max 0.0 samples)))
                      :over-20 (cl-count-if (lambda (x) (> x 0.02)) samples)
                      :over-100 (cl-count-if (lambda (x) (> x 0.1)) samples)))
    (push (cons label (plist-get final :max-ms)) etaf-weread-gui-acceptance--latencies)
    (etaf-weread-gui-acceptance--log "stall %s %S" label final)
    (etaf-weread-gui-acceptance--check (format "smooth %s" label)
                                       (< (plist-get final :max-ms) 250)
                                       (format "max lateness %sms" (plist-get final :max-ms)))
    final))

;;; ---------------------------------------------------------------------------
;;; Phases
;;; ---------------------------------------------------------------------------

(defun etaf-weread-gui-acceptance--browse ()
  "Accept the shelf, its sections, panes, search, index and statistics."
  ;; Mount and shelf.
  (let ((timeout 40))
    (etaf-weread-gui-acceptance--timed
     "mount+shelf"
     (progn
       (setq etaf-weread-gui-acceptance--settings
             (make-temp-file "weread-acceptance-" nil ".eld"))
       (let ((etaf-weread-settings-file etaf-weread-gui-acceptance--settings))
         (etaf-weread-gui-open "150x40"))
       (etaf-weread-gui-acceptance--wait
        (lambda () (> (or (plist-get (etaf-weread-gui-acceptance--state) :rows-total) 0) 0))
        timeout))))
  (let ((state (etaf-weread-gui-acceptance--state)))
    (etaf-weread-gui-acceptance--check "shelf rows" (> (plist-get state :rows-total) 0))
    (etaf-weread-gui-acceptance--check "account signed in"
                                       (let ((account (plist-get state :account)))
                                         (and account (not (string-empty-p (or (plist-get account :name) ""))))))
    (etaf-weread-gui-acceptance--check "shelf summary" (not (string-empty-p (or (plist-get state :summary) "")))))

  ;; List navigation.
  (etaf-weread-gui-acceptance--step "list selection and paging"
    (etaf-weread-gui-acceptance--keys "jj" 0.2)
    (etaf-weread-gui-acceptance--check "j moves down"
                                       (= 2 (plist-get (etaf-weread-gui-acceptance--state) :selection)))
    (etaf-weread-gui-acceptance--keys "<up>" 0.2)
    (etaf-weread-gui-acceptance--check "k moves up"
                                       (= 1 (plist-get (etaf-weread-gui-acceptance--state) :selection)))
    (etaf-weread-gui-acceptance--keys "<end>" 0.2)
    (let ((state (etaf-weread-gui-acceptance--state)))
      (etaf-weread-gui-acceptance--check "End goes last"
                                         (= (1- (plist-get state :rows-total))
                                            (plist-get state :selection))))
    (etaf-weread-gui-acceptance--keys "<home>" 0.2)
    (etaf-weread-gui-acceptance--check "Home goes first"
                                       (= 0 (plist-get (etaf-weread-gui-acceptance--state) :selection)))
    (etaf-weread-gui-acceptance--keys "<next>" 0.2)
    (etaf-weread-gui-acceptance--check "<next> pages down"
                                       (> (plist-get (etaf-weread-gui-acceptance--state) :selection) 0))
    (etaf-weread-gui-acceptance--keys "<prior><home>" 0.2)
    (etaf-weread-gui-acceptance--check "<prior> pages back"
                                       (= 0 (plist-get (etaf-weread-gui-acceptance--state) :selection))))

  ;; Sections and filters (real reloads).
  (dolist (case '(("s" . :shelf) ("2" . :reading) ("3" . :finished)
                  ("4" . :notebook) ("6" . :stats) ("7" . :index) ("L" . :local)))
    (etaf-weread-gui-acceptance--step (format "section %s" (car case))
      (etaf-weread-gui-acceptance--keys (car case) 0.3)
      (etaf-weread-gui-acceptance--wait
       (lambda () (eq (cdr case) (plist-get (etaf-weread-gui-acceptance--state) :section))) 15)
      (etaf-weread-gui-acceptance--check (format "section %s" (car case))
                                         (eq (cdr case) (plist-get (etaf-weread-gui-acceptance--state) :section)))))
  ;; Store search through the real command with a stubbed prompt.
  (etaf-weread-gui-acceptance--step "store search"
    (cl-letf (((symbol-function 'read-string)
               (etaf-weread-gui-acceptance--prompt-stub "三体")))
      (etaf-weread-gui-acceptance--keys "5" 0.5))
    (etaf-weread-gui-acceptance--wait
     (lambda () (eq :search (plist-get (etaf-weread-gui-acceptance--state) :mode))) 25)
    (etaf-weread-gui-acceptance--wait
     (lambda () (> (or (plist-get (etaf-weread-gui-acceptance--state) :rows-total) 0) 0)) 25)
    (let ((state (etaf-weread-gui-acceptance--state)))
      (etaf-weread-gui-acceptance--check
       "store search shown"
       (or (eq :search (plist-get state :mode))
           (eq :search (plist-get state :section)))
       (format "mode=%s section=%s" (plist-get state :mode) (plist-get state :section)))
      (etaf-weread-gui-acceptance--check "store results" (> (plist-get state :rows-total) 0))
      (etaf-weread-gui-acceptance--check "store query kept" (equal "三体" (plist-get state :query)))))

  ;; Book detail, highlights, chapter scroll, browser and export.
  (etaf-weread-gui-acceptance--step "detail pane"
    (etaf-weread-gui-acceptance--keys "s" 0.3)
    (etaf-weread-gui-acceptance--wait
     (lambda () (> (or (plist-get (etaf-weread-gui-acceptance--state) :rows-total) 0) 0)) 20)
    (etaf-weread-gui-acceptance--keys "RET" 0.5)
    (etaf-weread-gui-acceptance--wait
     (lambda () (plist-get (plist-get (etaf-weread-gui-acceptance--state) :detail) :title)) 15)
    (etaf-weread-gui-acceptance--check "detail follows selection"
                                       (plist-get (plist-get (etaf-weread-gui-acceptance--state) :detail) :title))
    (etaf-weread-gui-acceptance--keys "v" 0.5)
    (etaf-weread-gui-acceptance--wait
     (lambda () (plist-get (etaf-weread-gui-acceptance--state) :notes)) 15)
    (etaf-weread-gui-acceptance--check "highlights pane loads"
                                       (let ((notes (plist-get (etaf-weread-gui-acceptance--state) :notes)))
                                         (and notes (> (or (plist-get notes :count) 0) 0))))
    (etaf-weread-gui-acceptance--keys "v" 0.3))

  (etaf-weread-gui-acceptance--step "chapter list scroll"
    (let* ((state (etaf-weread-gui-acceptance--state))
           (chapters (length (or (plist-get (plist-get state :detail) :chapters) nil)))
           (rows (or (plist-get state :pane-rows) 1)))
      (if (<= chapters rows)
          (etaf-weread-gui-acceptance--check "chapter list scroll" t "list fits, nothing to scroll")
        (etaf-weread-gui-acceptance--keys "C-v" 0.3)
        (etaf-weread-gui-acceptance--check "chapter list scroll"
                                           (> (plist-get (etaf-weread-gui-acceptance--state) :pane-scroll) 0))
        (etaf-weread-gui-acceptance--keys "M-v" 0.3))))

  (etaf-weread-gui-acceptance--step "open in browser"
    (let ((opened nil))
      (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url))))
        (etaf-weread-gui-acceptance--keys "o" 0.3))
      (etaf-weread-gui-acceptance--check "open in browser reports a URL"
                                         (and opened (string-match-p "weread.qq.com" opened))
                                         (format "%S" opened))))

  (etaf-weread-gui-acceptance--step "export notes"
    (let ((etaf-weread-export-directory (make-temp-file "weread-acceptance-export-" t)))
      (etaf-weread-gui-acceptance--keys "E" 0.5)
      (etaf-weread-gui-acceptance--wait
       (lambda ()
         (let ((message (plist-get (etaf-weread-gui-acceptance--state) :message)))
           (and message (string-match-p "导出" message))))
       30)
      (etaf-weread-gui-acceptance--check
       "E exports the notes"
       (string-match-p "导出"
                       (or (plist-get (etaf-weread-gui-acceptance--state) :message) ""))
       (format "%S" (plist-get (etaf-weread-gui-acceptance--state) :message)))))

  ;; Local highlight index: view and filter what is stored.
  (etaf-weread-gui-acceptance--step "local index"
    (etaf-weread-gui-acceptance--keys "i" 0.5)
    (etaf-weread-gui-acceptance--wait
     (lambda () (eq :index (plist-get (etaf-weread-gui-acceptance--state) :section))) 15)
    (etaf-weread-gui-acceptance--check "index section"
                                       (eq :index (plist-get (etaf-weread-gui-acceptance--state) :section)))
    (cl-letf (((symbol-function 'read-string)
               (etaf-weread-gui-acceptance--prompt-stub "组件")))
      (etaf-weread-gui-acceptance--keys "/" 0.5))
    (etaf-weread-gui-acceptance--check "index filter"
                                       (equal "组件"
                                              (plist-get (etaf-weread-gui-acceptance--state) :index-query))))

  ;; Statistics section.
  (etaf-weread-gui-acceptance--step "statistics"
    (etaf-weread-gui-acceptance--keys "6" 1)
    (etaf-weread-gui-acceptance--check "stats loaded"
                                       (plist-get (etaf-weread-gui-acceptance--state) :stats))))

(defun etaf-weread-gui-acceptance--read-local (title)
  "Open the local book whose row contains TITLE through the real keys."
  (etaf-weread-gui-acceptance--keys "L" 0.5)
  (etaf-weread-gui-acceptance--wait
   (lambda () (> (or (plist-get (etaf-weread-gui-acceptance--state) :rows-total) 0) 0)) 15)
  (etaf-weread-gui-acceptance--select-row
   (lambda (row) (string-match-p (regexp-quote title) (or (plist-get row :title) "")))
   title)
  (etaf-weread-gui-acceptance--timed
   "open local chapter"
   (progn
     (etaf-weread-gui-acceptance--keys "RET" 0.8)
     (etaf-weread-gui-acceptance--check
      (format "open %s" title)
      (eq 'reader (plist-get (etaf-weread-gui-acceptance--state) :pane))))))

(defun etaf-weread-gui-acceptance--reading ()
  "Accept every reading key of the local books.
The long Vue.js chapter gives the scroll keys room to move, and the
multi-chapter 断舍离 gives the chapter keys a real table of contents."
  ;; --- one long chapter: scrolling, layout, appearance, notes, lookup ---
  (etaf-weread-gui-acceptance--read-local "Vue.js设计与实现")
  (let ((state (etaf-weread-gui-acceptance--state)))
    (etaf-weread-gui-acceptance--check
     "the chapter scrolls"
     (> (plist-get state :pane-total) (plist-get state :reader-rows))
     (format "total=%s rows=%s" (plist-get state :pane-total)
             (plist-get state :reader-rows))))

  (etaf-weread-gui-acceptance--step "reading scroll keys"
    (etaf-weread-gui-acceptance--keys "g" 0.3)
    (etaf-weread-gui-acceptance--keys "jjjjj" 0.3)
    (etaf-weread-gui-acceptance--check "j scrolls the chapter"
                                       (= 5 (plist-get (etaf-weread-gui-acceptance--state)
                                                       :pane-scroll))
                                       (format "scroll=%s"
                                               (plist-get (etaf-weread-gui-acceptance--state)
                                                          :pane-scroll)))
    (etaf-weread-gui-acceptance--keys "<up>" 0.2)
    (etaf-weread-gui-acceptance--check "k scrolls back"
                                       (= 4 (plist-get (etaf-weread-gui-acceptance--state)
                                                       :pane-scroll))
                                       (format "scroll=%s"
                                               (plist-get (etaf-weread-gui-acceptance--state)
                                                          :pane-scroll)))
    (etaf-weread-gui-acceptance--keys "SPC" 0.3)
    (etaf-weread-gui-acceptance--check "SPC pages"
                                       (> (plist-get (etaf-weread-gui-acceptance--state)
                                                     :pane-scroll)
                                          4)
                                       (format "scroll=%s"
                                               (plist-get (etaf-weread-gui-acceptance--state)
                                                          :pane-scroll)))
    (etaf-weread-gui-acceptance--keys "g" 0.3)
    (etaf-weread-gui-acceptance--check "g goes to the chapter start"
                                       (= 0 (plist-get (etaf-weread-gui-acceptance--state)
                                                       :pane-scroll)))
    (etaf-weread-gui-acceptance--keys "G" 0.3)
    (etaf-weread-gui-acceptance--check "G goes to the chapter end"
                                       (> (plist-get (etaf-weread-gui-acceptance--state)
                                                     :pane-scroll)
                                          0))
    (etaf-weread-gui-acceptance--keys "g" 0.2))

  (etaf-weread-gui-acceptance--step "reading width and spread"
    (let ((width (plist-get (etaf-weread-gui-acceptance--state) :reader-measure)))
      (etaf-weread-gui-acceptance--keys "]" 0.3)
      (etaf-weread-gui-acceptance--check "] widens the column"
                                         (> (plist-get (etaf-weread-gui-acceptance--state)
                                                       :reader-measure)
                                            width))
      (etaf-weread-gui-acceptance--keys "[" 0.3))
    (let ((spread (plist-get (etaf-weread-gui-acceptance--state) :reader-spread)))
      (etaf-weread-gui-acceptance--keys "m" 0.3)
      (etaf-weread-gui-acceptance--check
       "m cycles the columns"
       (not (equal spread
                   (plist-get (etaf-weread-gui-acceptance--state) :reader-spread))))))

  (etaf-weread-gui-acceptance--step "font presets"
    (let ((font (plist-get (etaf-weread-gui-acceptance--state) :reader-font)))
      (etaf-weread-gui-acceptance--keys "F" 0.5)
      (etaf-weread-gui-acceptance--check
       "F cycles the font"
       (not (eq font (plist-get (etaf-weread-gui-acceptance--state) :reader-font))))
      (etaf-weread-gui-acceptance--check "font keeps the canvas inside the window"
                                         (null (etaf-weread-gui-check))
                                         (format "%S" (etaf-weread-gui-check)))
      (etaf-weread-gui-acceptance--keys "F" 0.5)
      (etaf-weread-gui-acceptance--keys "F" 0.5)))

  (etaf-weread-gui-acceptance--step "zen"
    (etaf-weread-gui-acceptance--keys "f" 0.5)
    (etaf-weread-gui-acceptance--check "f enters zen"
                                       (plist-get (etaf-weread-gui-acceptance--state) :zen))
    (etaf-weread-gui-acceptance--check "zen keeps the layout healthy"
                                       (null (etaf-weread-gui-check))
                                       (format "%S" (etaf-weread-gui-check)))
    (etaf-weread-gui-acceptance--keys "f" 0.5)
    (etaf-weread-gui-acceptance--check "f leaves zen"
                                       (not (plist-get (etaf-weread-gui-acceptance--state) :zen))))

  (etaf-weread-gui-acceptance--step "auto-scroll"
    (etaf-weread-gui-acceptance--keys "g" 0.2)
    (let ((etaf-weread-auto-scroll-interval 0.4))
      (etaf-weread-gui-acceptance--keys "a" 0.2))
    (sit-for 1.4)
    (etaf-weread-gui--flush)
    (etaf-weread-gui-acceptance--check
     "a advances by itself"
     (> (plist-get (etaf-weread-gui-acceptance--state) :pane-scroll) 0)
     (format "scroll=%s" (plist-get (etaf-weread-gui-acceptance--state) :pane-scroll)))
    (let ((etaf-weread-auto-scroll-interval 0.4))
      (etaf-weread-gui-acceptance--keys "a" 0.2))
    (etaf-weread-gui-acceptance--check "a stops"
                                       (not (plist-get (etaf-weread-gui-acceptance--state)
                                                       :auto-scroll))))

  ;; The key passes the line being read to the configured backend; the real
  ;; macOS dictionary is then asked for a word it certainly has.
  (etaf-weread-gui-acceptance--step "dictionary lookup"
    (when (get-buffer etaf-weread-dictionary-buffer-name)
      (kill-buffer etaf-weread-dictionary-buffer-name))
    (etaf-weread-gui-acceptance--keys "g" 0.3)
    (let ((queries nil))
      (let ((etaf-weread-dictionary-function
             (lambda (query) (push query queries))))
        (etaf-weread-gui-acceptance--keys "y" 0.5))
      (etaf-weread-gui-acceptance--check
       "y looks the reading line up"
       (and queries (not (string-empty-p (car queries))))
       (format "%S" queries)))
    (when (eq system-type 'darwin)
      (let ((query (etaf-weread-lookup etaf-weread-gui--model "ephemeral")))
        (etaf-weread-gui-acceptance--check "macOS dictionary answers"
                                           (equal "ephemeral" query)
                                           (format "%S" query)))))

  (etaf-weread-gui-acceptance--step "reading statistics"
    (let ((stats (etaf-weread-reading-stats etaf-weread-gui--model)))
      (etaf-weread-gui-acceptance--check "a local book keeps a reading record" stats)))

  ;; The WeChat highlight overlay on a book the account has notes for.
  (etaf-weread-gui-acceptance--step "local notes overlay"
    (etaf-weread-gui-acceptance--keys "v" 0.4)
    (etaf-weread-gui-acceptance--read-local "Vue.js设计与实现")
    (etaf-weread-gui-acceptance--wait
     (lambda ()
       (let ((notes (plist-get (etaf-weread-gui-acceptance--state) :local-notes)))
         (and notes (plist-get notes :book-id))))
     40)
    ;; One retry, because a single backend reply may be lost on a busy machine.
    (unless (plist-get (plist-get (etaf-weread-gui-acceptance--state) :local-notes)
                       :book-id)
      (etaf-weread-match-local-notes etaf-weread-gui--model t)
      (etaf-weread-gui-acceptance--wait
       (lambda ()
         (let ((notes (plist-get (etaf-weread-gui-acceptance--state) :local-notes)))
           (and notes (plist-get notes :book-id))))
       40))
    (let* ((state (etaf-weread-gui-acceptance--state))
           (notes (plist-get state :local-notes))
           (matches (plist-get notes :notes)))
      (etaf-weread-gui-acceptance--check
       "highlights match the local book"
       (> (length matches) 0)
       (format "book=%s matches=%s error=%S message=%S"
               (plist-get notes :book-id) (length matches)
               (plist-get state :error) (plist-get state :message)))
      (when matches
        (etaf-weread-gui-acceptance--check
         "matching lines carry the mark"
         (seq-some (lambda (line) (plist-get line :note))
                   (or (plist-get (etaf-weread-gui-acceptance--state) :reader-lines))))
        (etaf-weread-gui-acceptance--keys "N" 1)
        (etaf-weread-gui-acceptance--check
         "N jumps to a highlight"
         (string-match-p "笔记"
                         (or (plist-get (etaf-weread-gui-acceptance--state) :message) "")))
        (cl-letf (((symbol-function 'completing-read)
                   (etaf-weread-gui-acceptance--first-choice)))
          (etaf-weread-gui-acceptance--keys "M" 0.8))
        (etaf-weread-gui-acceptance--check
         "M chooses a highlight"
         (string-match-p "笔记"
                         (or (plist-get (etaf-weread-gui-acceptance--state) :message) ""))))))

  ;; --- many chapters: turning, picking, searching, bookmarks, memory ---
  (etaf-weread-gui-acceptance--step "chapter turning"
    (etaf-weread-gui-acceptance--keys "v" 0.4)
    (etaf-weread-gui-acceptance--read-local "断舍离")
    (etaf-weread-gui-acceptance--keys "<next>" 0.5)
    (etaf-weread-gui-acceptance--check
     "<next> turns the chapter"
     (= 1 (plist-get (plist-get (etaf-weread-gui-acceptance--state) :local) :index))
     (format "index=%s" (plist-get (plist-get (etaf-weread-gui-acceptance--state) :local)
                                   :index)))
    (etaf-weread-gui-acceptance--keys "<prior>" 0.5)
    (etaf-weread-gui-acceptance--check
     "<prior> turns back"
     (= 0 (plist-get (plist-get (etaf-weread-gui-acceptance--state) :local) :index))))

  (etaf-weread-gui-acceptance--step "chapter picker"
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (let ((third (nth 2 collection)))
                   (if (consp third) (car third) third)))))
      (etaf-weread-gui-acceptance--keys "c" 0.6))
    (etaf-weread-gui-acceptance--check
     "c picks the third chapter"
     (= 2 (plist-get (plist-get (etaf-weread-gui-acceptance--state) :local) :index))
     (format "index=%s" (plist-get (plist-get (etaf-weread-gui-acceptance--state) :local)
                                   :index))))

  (etaf-weread-gui-acceptance--step "in-book search"
    (let* ((matches (etaf-weread-search-local-book etaf-weread-gui--model "习惯"))
           (target (and matches (plist-get (car matches) :chapter))))
      (cl-letf (((symbol-function 'read-string)
                 (etaf-weread-gui-acceptance--prompt-stub "习惯"))
                ((symbol-function 'completing-read)
                 (etaf-weread-gui-acceptance--first-choice)))
        (etaf-weread-gui-acceptance--keys "/" 0.6))
      (etaf-weread-gui-acceptance--check
       "in-book search jumps to a match"
       (and target
            (= target (plist-get (plist-get (etaf-weread-gui-acceptance--state) :local)
                                 :index)))
       (format "target=%s actual=%s" target
               (plist-get (plist-get (etaf-weread-gui-acceptance--state) :local) :index)))))

  (etaf-weread-gui-acceptance--step "percentage jump"
    (cl-letf (((symbol-function 'read-string)
               (etaf-weread-gui-acceptance--prompt-stub "50")))
      (etaf-weread-gui-acceptance--keys "%" 0.6))
    (let ((progress (plist-get (etaf-weread-gui-acceptance--state) :reader-progress)))
      (etaf-weread-gui-acceptance--check "percent jump moves the progress"
                                         (and progress (> progress 40) (< progress 60))
                                         (format "%s" progress))))

  (etaf-weread-gui-acceptance--step "bookmarks"
    (etaf-weread-gui-acceptance--keys "g" 0.2)
    (etaf-weread-gui-acceptance--keys "b" 0.3)
    (let ((chapter (plist-get (plist-get (etaf-weread-gui-acceptance--state) :local) :index))
          (scroll (plist-get (etaf-weread-gui-acceptance--state) :pane-scroll)))
      (etaf-weread-gui-acceptance--check
       "b adds a bookmark"
       (string-match-p "已加书签"
                       (or (plist-get (etaf-weread-gui-acceptance--state) :message) ""))
       (format "%S" (plist-get (etaf-weread-gui-acceptance--state) :message)))
      (etaf-weread-gui-acceptance--keys "<next>" 0.5)
      (cl-letf (((symbol-function 'completing-read)
                 (etaf-weread-gui-acceptance--first-choice)))
        (etaf-weread-gui-acceptance--keys "B" 0.8))
      (let* ((state (etaf-weread-gui-acceptance--state))
             (back-chapter (plist-get (plist-get state :local) :index))
             (back-scroll (plist-get state :pane-scroll)))
        (etaf-weread-gui-acceptance--check
         "B jumps back to the bookmark"
         (and (= chapter back-chapter) (<= (abs (- scroll back-scroll)) 1))
         (format "chapter=%s/%s scroll=%s/%s" chapter back-chapter scroll back-scroll)))
      (etaf-weread-gui-acceptance--keys "b" 0.3)
      (etaf-weread-gui-acceptance--check
       "b removes the same bookmark"
       (string-match-p "已取消书签"
                       (or (plist-get (etaf-weread-gui-acceptance--state) :message) "")))))

  (etaf-weread-gui-acceptance--step "position memory"
    (cl-letf (((symbol-function 'read-string)
               (etaf-weread-gui-acceptance--prompt-stub "50")))
      (etaf-weread-gui-acceptance--keys "%" 0.6))
    (let ((expected (plist-get (plist-get (etaf-weread-gui-acceptance--state) :local) :index)))
      (etaf-weread-gui-acceptance--keys "v" 0.4)
      (etaf-weread-gui-acceptance--read-local "断舍离")
      (let ((actual (plist-get (plist-get (etaf-weread-gui-acceptance--state) :local) :index)))
        (etaf-weread-gui-acceptance--check "position restored"
                                           (= expected actual)
                                           (format "expected=%s actual=%s" expected actual)))))

  ;; Theme cycle.
  (etaf-weread-gui-acceptance--step "theme cycle"
    (dotimes (_ 4)
      (etaf-weread-gui-acceptance--keys "T" 0.5)
      (etaf-weread-gui-acceptance--check "theme repaints healthy"
                                         (null (etaf-weread-gui-check))
                                         (format "%S" (etaf-weread-gui-check))))))


(defun etaf-weread-gui-acceptance--press-cost (label key count)
  "Press KEY COUNT times and record each repaint's cost under LABEL.
The measurement is the real key through the command loop plus the renderer
flush it triggers, which is what a person waits for between two repaints."
  (let ((values nil))
    (dotimes (_ count)
      (let ((started (float-time)))
        (etaf-weread-gui-acceptance--keys key 0)
        (let ((elapsed (round (* 1000 (- (float-time) started)))))
          (push elapsed values)
          (push (cons label elapsed) etaf-weread-gui-acceptance--latencies))))
    (let* ((sorted (sort (copy-sequence values) #'<))
           (median (nth (/ (length sorted) 2) sorted))
           (maximum (car (last sorted))))
      (etaf-weread-gui-acceptance--log "press %s n=%s median=%sms max=%sms"
                                       label (length values) median maximum)
      (etaf-weread-gui-acceptance--check (format "%s press median" label)
                                         (< median 250)
                                         (format "median=%sms max=%sms" median maximum))
      (list :median median :max maximum))))

(defun etaf-weread-gui-acceptance--smoothness ()
  "Measure timer lateness while the reader repaints under real keys."
  (etaf-weread-gui-acceptance--step "smooth shelf selection"
    (etaf-weread-gui-acceptance--keys "v" 0.4)
    (etaf-weread-gui-acceptance--keys "s" 0.4)
    (etaf-weread-gui-acceptance--keys "<home>" 0.3)
    (etaf-weread-gui-acceptance--press-cost "shelf selection" "<down>" 8)
    (etaf-weread-gui-acceptance--stall "shelf selection" 1.6 "<down>"))
  (etaf-weread-gui-acceptance--step "smooth section switch"
    (etaf-weread-gui-acceptance--timed "section switch"
      (etaf-weread-gui-acceptance--keys "4" 0.5))
    (etaf-weread-gui-acceptance--check "section switch lands"
                                       (eq :notebook
                                           (plist-get (etaf-weread-gui-acceptance--state) :section))))
  (etaf-weread-gui-acceptance--step "smooth chapter scroll"
    (etaf-weread-gui-acceptance--read-local "Vue.js设计与实现")
    (etaf-weread-gui-acceptance--keys "g" 0.2)
    (etaf-weread-gui-acceptance--press-cost "chapter scroll" "<down>" 8)
    (etaf-weread-gui-acceptance--stall "chapter scroll" 1.6 "<down>")))

(defun etaf-weread-gui-acceptance--close ()
  "Close the reader and check the buffer is gone."
  (etaf-weread-gui-acceptance--step "close"
    (etaf-weread-gui-acceptance--keys "q" 0.5)
    (etaf-weread-gui-acceptance--check "q closes the reader"
                                       (not (get-buffer etaf-weread-buffer-name)))))

(defun etaf-weread-gui-acceptance-run ()
  "Run the whole acceptance pass and return (PLIST :problems …).
The pass uses the real account and the real keymap; the session keeps its
preferences in a disposable file, so the user's settings are untouched."
  (setq etaf-weread-gui-acceptance--problems nil
        etaf-weread-gui-acceptance--latencies nil
        etaf-weread-gui-acceptance--steps 0)
  (etaf-weread-gui-acceptance--log "== acceptance start ==")
  (unwind-protect
      (progn
        (etaf-weread-gui-acceptance--browse)
        (etaf-weread-gui-acceptance--reading)
        (etaf-weread-gui-acceptance--smoothness)
        (etaf-weread-gui-acceptance--layout-matrix)
        (etaf-weread-gui-acceptance--close))
    (when (and etaf-weread-gui-acceptance--settings
               (file-exists-p etaf-weread-gui-acceptance--settings))
      (ignore-errors (delete-file etaf-weread-gui-acceptance--settings))))
  (let ((report (list :steps etaf-weread-gui-acceptance--steps
                      :problems (nreverse etaf-weread-gui-acceptance--problems)
                      :latencies (nreverse etaf-weread-gui-acceptance--latencies))))
    (etaf-weread-gui-acceptance--log "== acceptance done: %S ==" report)
    report))

(provide 'weread-gui-acceptance)
;;; weread-gui-acceptance.el ends here
