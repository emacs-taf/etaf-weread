;;; etaf-weread-library.el --- Local books the reader can open -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The reader shows the account's shelf, notebook and highlights; the body of
;; a WeChat Reading title stays inside its own canvas-protected reader.  A book
;; the person already holds as a file is different: it is theirs, the text is
;; plain, and Emacs can page through it.  This module scans a configured
;; directory and turns TXT, Markdown and EPUB files into the same chapter shape
;; the backend uses, so the model and the views need no special case for a
;; local book.
;;
;; EPUB needs the `unzip' program; TXT and Markdown need nothing.
;;
;; The two entry points are declared in the package entry's Commentary, which
;; is the authoritative public API inventory.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'dom)
(require 'url-util)
(require 'etaf-weread-theme)

(defcustom etaf-weread-library-directory (expand-file-name "~/ebooks")
  "Directory scanned for local books the reader can open.
The scan walks subdirectories (a library is usually grouped by subject), up to
`etaf-weread-library-depth' levels."
  :type 'directory
  :group 'etaf-weread)

(defcustom etaf-weread-library-depth 4
  "Directory levels `etaf-weread-library-books' walks below its root."
  :type 'integer
  :group 'etaf-weread)

(defcustom etaf-weread-library-extensions '("txt" "text" "md" "markdown" "epub")
  "File extensions offered as local books, lower case without the dot."
  :type '(repeat string)
  :group 'etaf-weread)

(defcustom etaf-weread-library-chapter-length 6000
  "Characters before a heading-less text file starts another chapter."
  :type 'integer
  :group 'etaf-weread)

(defvar etaf-weread-library--heading-regexp
  (concat "^\\s-*\\(?:"
          "第[0-9一二三四五六七八九十百千零〇]+[章节回卷篇]"
          "\\|[0-9]+[、.．]\\s-*\\S-"
          "\\|Chapter\\s-+[0-9IVXLC]+"
          "\\)")
  "Line start of a chapter heading inside a plain text file.")

(defun etaf-weread-library--format (path)
  "Return the lower-case book format of PATH, or nil."
  (let ((extension (downcase (or (file-name-extension path) ""))))
    (and (member extension etaf-weread-library-extensions) extension)))

(defun etaf-weread-library--title-for (path)
  "Return a readable title for PATH from its file name."
  (let ((base (file-name-base path)))
    (string-trim
     (replace-regexp-in-string "[[:space:]]*[([].*?[)\]]?[[:space:]]*$" ""
                               (replace-regexp-in-string "[_]+" " " base)))))

(defun etaf-weread-library--files (directory depth)
  "Return the book files under DIRECTORY, walking DEPTH levels deeper.
Hidden directories are skipped so a version-control or cache directory cannot
flood the library."
  (let ((entries nil))
    (dolist (path (ignore-errors (directory-files directory t "\\`[^.]" t)))
      (cond
       ((file-directory-p path)
        (when (> depth 1)
          (setq entries (nconc entries (etaf-weread-library--files path (1- depth))))))
       ((etaf-weread-library--format path) (push path entries))))
    entries))

(defun etaf-weread-library-books (&optional directory)
  "Return every local book under DIRECTORY as plists.
Each plist is (:path :title :author :format :size).  DIRECTORY defaults to
`etaf-weread-library-directory' and is walked up to
`etaf-weread-library-depth' levels; a missing or unreadable directory returns
nil."
  (let ((directory (or directory etaf-weread-library-directory)))
    (when (file-directory-p directory)
      (sort (mapcar
             (lambda (path)
               (list :path path
                     :title (etaf-weread-library--title-for path)
                     :author ""
                     :format (etaf-weread-library--format path)
                     :size (nth 7 (file-attributes path))))
             (etaf-weread-library--files directory etaf-weread-library-depth))
            (lambda (a b) (string< (plist-get a :title) (plist-get b :title)))))))

(defun etaf-weread-library--read-file (path)
  "Return PATH's text, decoding the coding system the file actually uses."
  (unless (file-readable-p path)
    (signal 'etaf-weread-error (list (format "无法读取本地文件：%s" path))))
  (with-temp-buffer
    (insert-file-contents-literally path)
    (let ((coding (car (detect-coding-region (point-min) (point-max)))))
      (when (and coding (not (eq coding 'undecided)))
        (decode-coding-region (point-min) (point-max) coding)))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-weread-library--paragraphs (text)
  "Return TEXT with runs of blank lines collapsed to one blank line."
  (replace-regexp-in-string "\n\\{3,\\}" "\n\n"
                            (replace-regexp-in-string "\r\n?" "\n" text)))

(defun etaf-weread-library--chunk-at-headings (text)
  "Split TEXT at heading lines, or at paragraph breaks every chapter length.
Return a list of (TITLE . BODY); the first chunk may carry the file's own
title line."
  (let ((chunks nil)
        (current-title nil)
        (current-lines nil)
        (length 0))
    (cl-labels ((flush ()
                  (when current-lines
                    (push (cons (or current-title "")
                                (string-trim (mapconcat #'identity (nreverse current-lines) "\n")))
                          chunks)
                    (setq current-lines nil length 0))))
      (dolist (line (split-string (etaf-weread-library--paragraphs text) "\n"))
        (cond
         ((string-match-p etaf-weread-library--heading-regexp line)
          (flush)
          (setq current-title (string-trim line)))
         ((and (> (+ length (length line)) etaf-weread-library-chapter-length)
               (string-empty-p (string-trim line)))
          (flush)
          (push line current-lines)
          (setq length (length line)))
         (t (push line current-lines) (setq length (+ length (length line) 1)))))
      (flush))
    (nreverse chunks)))

(defun etaf-weread-library--text-chapters (text)
  "Return chapters of TEXT as (:title :text) plists.
A heading line starts a chapter; without headings, long text is cut at a
paragraph break so a chapter stays readable in one pane."
  (let ((chunks (etaf-weread-library--chunk-at-headings text)))
    (when (and chunks (string-empty-p (car (car chunks))))
      (setcar (car chunks) "正文"))
    (mapcar (lambda (chunk)
              (list :title (if (string-empty-p (car chunk)) "正文" (car chunk))
                    :text (cdr chunk)))
            chunks)))

(defun etaf-weread-library--markdown-chapters (text)
  "Return chapters of the Markdown document TEXT as (:title :text) plists."
  (let ((chunks nil) (title nil) (lines nil))
    (cl-labels ((flush ()
                  (when lines
                    (push (list :title (or title "正文")
                                :text (string-trim (mapconcat #'identity (nreverse lines) "\n")))
                          chunks)
                    (setq lines nil))))
      (dolist (line (split-string (etaf-weread-library--paragraphs text) "\n"))
        (if (string-match "\\`#\\{1,3\\} +\\(.+\\)" line)
            (progn (flush) (setq title (string-trim (match-string 1 line))))
          (push line lines)))
      (flush))
    (nreverse chunks)))

(defun etaf-weread-library--dom-text (node)
  "Return the plain text of DOM NODE.
Block elements break lines, so paragraphs survive.  Only `dom-children' is
walked: a node's cdr also carries attribute conses, and those are not text.
Markup-only nodes are skipped whole: an XHTML entry opens with the XML
declaration, which libxml reports as a comment node holding that text."
  (cond
   ((stringp node) node)
   ((memq (car-safe node) '(comment processing-instruction)) "")
   ((consp node)
    (let ((block (memq (dom-tag node)
                       '(p div h1 h2 h3 h4 h5 h6 li tr br blockquote section article)))
          (parts nil))
      (when block (push "\n" parts))
      (dolist (child (dom-children node)) (push (etaf-weread-library--dom-text child) parts))
      (when block (push "\n" parts))
      (apply #'concat (nreverse parts))))
   (t "")))

(defun etaf-weread-library--html-text (html)
  "Return readable plain text of the XHTML fragment HTML."
  (let* ((dom (condition-case nil
                  (with-temp-buffer
                    (insert html)
                    (libxml-parse-html-region (point-min) (point-max)))
                (error nil)))
         (text (and dom (etaf-weread-library--dom-text dom))))
    (when text
      (string-trim
       (replace-regexp-in-string
        "[ \t]+" " "
        (replace-regexp-in-string "\n\\{3,\\}" "\n\n" text))))))

(defun etaf-weread-library--epub-entry (path entry)
  "Return the text of ENTRY inside the EPUB at PATH, or nil."
  (with-temp-buffer
    (let ((status (ignore-errors
                    (call-process "unzip" nil (current-buffer) nil "-p" path entry))))
      (when (and (integerp status) (zerop status) (> (buffer-size) 0))
        (decode-coding-string (buffer-string) 'utf-8)))))

(defun etaf-weread-library--epub-spine (path)
  "Return the reading order of the EPUB at PATH as a list of entry names."
  (let* ((container (etaf-weread-library--epub-entry path "META-INF/container.xml"))
         (rootfile (and container
                        (with-temp-buffer
                          (insert container)
                          (ignore-errors
                            (let ((dom (libxml-parse-xml-region (point-min) (point-max))))
                              (and dom (dom-attr (car (dom-by-tag dom 'rootfile)) 'full-path))))))))
    (when rootfile
      (let* ((base (file-name-directory rootfile))
             (opf (etaf-weread-library--epub-entry path rootfile))
             (manifest nil) (spine nil))
        (when opf
          (with-temp-buffer
            (insert opf)
            (let ((dom (ignore-errors (libxml-parse-xml-region (point-min) (point-max)))))
              (dolist (item (dom-by-tag dom 'item))
                (push (cons (dom-attr item 'id) (dom-attr item 'href)) manifest))
              (dolist (ref (dom-by-tag dom 'itemref))
                (when-let* ((href (cdr (assoc (dom-attr ref 'idref) manifest))))
                  (push (concat base href) spine))))))
        (nreverse spine)))))

(defun etaf-weread-library--epub-chapters (path)
  "Return the chapters of the EPUB at PATH as (:title :text) plists."
  (let ((spine (etaf-weread-library--epub-spine path)))
    (unless spine
      (signal 'etaf-weread-error (list (format "无法解析 EPUB 目录：%s" path))))
    (let ((chapters nil) (index 0))
      (dolist (entry spine)
        (let* ((html (etaf-weread-library--epub-entry path (url-unhex-string entry)))
               (text (and html (etaf-weread-library--html-text html))))
          (when (and text (not (string-empty-p text)))
            (cl-incf index)
            (push (list :title (or (car (split-string text "\n")) (format "第 %d 节" index))
                        :text text)
                  chapters))))
      (nreverse chapters))))

(defun etaf-weread-library-content (path)
  "Read the local book at PATH and return (:title :author :format :chapters).
CHAPTERS is a list of (:title :text) in reading order, the shape a backend
book reply carries.  A missing, unsupported or unreadable file signals
`etaf-weread-error'."
  (let ((format (etaf-weread-library--format path)))
    (unless format
      (signal 'etaf-weread-error
              (list (format "不支持的本地书籍格式：%s" (file-name-nondirectory path))))))
  (let* ((format (etaf-weread-library--format path))
         (chapters (pcase format
                     ((or "txt" "text") (etaf-weread-library--text-chapters
                                         (etaf-weread-library--read-file path)))
                     ((or "md" "markdown") (etaf-weread-library--markdown-chapters
                                            (etaf-weread-library--read-file path)))
                     ((or "epub") (etaf-weread-library--epub-chapters path)))))
    (when (null chapters)
      (signal 'etaf-weread-error (list (format "本地书籍没有可读内容：%s" path))))
    (list :title (etaf-weread-library--title-for path)
          :author ""
          :format format
          :chapters chapters)))

(provide 'etaf-weread-library)
;;; etaf-weread-library.el ends here
