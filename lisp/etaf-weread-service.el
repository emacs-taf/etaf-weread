;;; etaf-weread-service.el --- WeChat Reading backend client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The reader does not re-implement the WeChat Reading protocol.  It drives the
;; `weread' Pi skill through its documented command line:
;;
;;   node <skill>/scripts/weread.mjs COMMAND ... --json --quiet
;;
;; Every command prints JSON.  Requests are plists such as
;; (:op :shelf :filter reading :limit 200) and every call is asynchronous:
;; CALLBACK runs later in the Emacs event loop with (:ok DATA) or
;; (:error MESSAGE :hint HINT).  Nothing here blocks, so the interface keeps
;; repainting while a request is in flight.
;;
;; Tests replace the transport by binding `etaf-weread-client-factory' to a
;; function returning a fake client, so no scenario needs the network or a
;; login.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'etaf-weread-theme)

(defcustom etaf-weread-skill-directory
  (expand-file-name "~/.pi/agent/shared/skills/weread")
  "Directory holding the weread skill scripts.
`etaf-weread-make-client' uses it to locate `scripts/weread.mjs'."
  :type 'directory
  :group 'etaf-weread)

(defcustom etaf-weread-node-program "node"
  "Node executable used to run the skill's API client."
  :type 'string
  :group 'etaf-weread)

(defcustom etaf-weread-request-timeout 45
  "Seconds before a backend request is abandoned.
The timer kills the child process, so a hung request cannot pin a pending
callback forever.  Callers see (:error MESSAGE)."
  :type 'number
  :group 'etaf-weread)

(defcustom etaf-weread-export-directory nil
  "Directory the skill writes exported Markdown into, or nil for its default.
When non-nil it is passed to the skill as `--out', which wins over the skill's
own configuration."
  :type '(choice (const :tag "Skill default" nil) directory)
  :group 'etaf-weread)

(defvar etaf-weread-client-factory nil
  "Function returning the backend client used by new sessions.
It is called with no arguments and must return a client built by
`etaf-weread-make-client', or any function accepting (REQUEST CALLBACK) as
`etaf-weread-client-call' documents.  Nil selects the default subprocess
client; tests bind this to a fake client.")

(cl-defstruct (etaf-weread--client (:constructor etaf-weread--client-create))
  "Backend client that runs the weread skill as child processes."
  skill-directory node-program timeout (pending nil))

(cl-defstruct (etaf-weread--pending (:constructor etaf-weread--pending-create))
  "One in-flight backend request."
  process timer cancelled stdout stderr)

(cl-defun etaf-weread-make-client (&key skill-directory node-program timeout)
  "Create a client that runs the weread skill as child processes.
SKILL-DIRECTORY, NODE-PROGRAM and TIMEOUT default to
`etaf-weread-skill-directory', `etaf-weread-node-program' and
`etaf-weread-request-timeout'."
  (etaf-weread--client-create
   :skill-directory (or skill-directory etaf-weread-skill-directory)
   :node-program (or node-program etaf-weread-node-program)
   :timeout (or timeout etaf-weread-request-timeout)))

(defun etaf-weread-client-call (client request callback)
  "Send REQUEST through CLIENT and deliver the reply to CALLBACK.
CLIENT is a client from `etaf-weread-make-client' or a function of two
arguments (REQUEST CALLBACK), which is how tests inject a fake.

REQUEST is a plist whose `:op' selects one backend operation:

  :status    (:op :status)                              the stored login
  :shelf     (:op :shelf :filter all :limit 200)        books and progress
  :notebook  (:op :notebook :limit 200)                 books with notes
  :book      (:op :book :id \"3300144445\")              info, TOC and progress
  :notes     (:op :notes :id \"3300144445\")             highlights and thoughts
  :search    (:op :search :keyword \"三体\" :count 25)
  :stats     (:op :stats)                               aggregate reading stats
  :export    (:op :export :id \"3300144445\")            write the notes Markdown

CALLBACK receives exactly one of (:ok DATA), where DATA is the decoded JSON
plist, or (:error MESSAGE :hint HINT) when the command failed, timed out or
returned a backend error.  Requests run in the background, so CALLBACK may run
long after the call returns."
  (if (etaf-weread--client-p client)
      (etaf-weread--client-request client request callback)
    (if (functionp client)
        (funcall client request callback)
      (signal 'etaf-weread-error (list (format "Not a backend client: %S" client))))))

(defun etaf-weread-cancel (client)
  "Abandon every in-flight request of CLIENT.
Cancelled requests never run their callbacks.  Return the number of cancelled
requests, or 0 when CLIENT is not a subprocess client."
  (let ((count 0))
    (when (etaf-weread--client-p client)
      (dolist (pending (etaf-weread--client-pending client))
        (setf (etaf-weread--pending-cancelled pending) t)
        (when-let* ((timer (etaf-weread--pending-timer pending)))
          (cancel-timer timer))
        (when-let* ((process (etaf-weread--pending-process pending)))
          (when (process-live-p process)
            (cl-incf count)
            (delete-process process))))
      (setf (etaf-weread--client-pending client) nil))
    count))

(defun etaf-weread--client-request (client request callback)
  "Run REQUEST through the skill process of CLIENT, then call CALLBACK."
  (let ((command (condition-case error
                     (etaf-weread--client-command client request)
                   (error (funcall callback
                                   (list :error (error-message-string error)))
                          nil))))
    (when command
      (etaf-weread--spawn client (car command) (cdr command) callback))))

(defun etaf-weread--client-command (client request)
  "Return the command line for REQUEST as (PROGRAM . ARGUMENTS).
The result is ready for `make-process': its first element is the program and
the rest are the arguments.  Signal `etaf-weread-error' for an unknown request."
  (let* ((skill (etaf-weread--client-skill-directory client))
         (script (expand-file-name "scripts/weread.mjs" skill))
         (node (etaf-weread--client-node-program client)))
    (unless (file-readable-p script)
      (signal 'etaf-weread-error
              (list (format "weread skill script is missing: %s" script))))
    (unless (executable-find node)
      (signal 'etaf-weread-error (list (format "Executable is missing: %s" node))))
    (cons node
          (append (list script)
                  (etaf-weread--command-arguments request)
                  (list "--json" "--quiet")
                  (etaf-weread--export-arguments request)))))

(defun etaf-weread--command-arguments (request)
  "Return the skill command arguments for REQUEST.
Only `:export' writes, and it always overrides the skill's preview default
with `--yes' because the reader asks before calling this function."
  (let ((op (plist-get request :op))
        (id (plist-get request :id))
        (limit (or (plist-get request :limit) 200)))
    (pcase op
      (:status (list "status"))
      (:shelf (append (list "shelf" "--filter"
                            (or (plist-get request :filter) "all"))
                      (list "--limit" (number-to-string limit))))
      (:notebook (list "notes" "--limit" (number-to-string limit)))
      ((or :book :notes)
       (unless (and id (not (string-empty-p (format "%s" id))))
         (signal 'etaf-weread-error (list (format "%s needs a book id" op))))
       (list (if (eq op :book) "book" "notes") (format "%s" id)))
      (:search
       (let ((keyword (string-trim (or (plist-get request :keyword) ""))))
         (when (string-empty-p keyword)
           (signal 'etaf-weread-error '("搜索关键词不能为空")))
         (list "search" keyword "--count"
               (number-to-string (or (plist-get request :count) 25)))))
      (:stats (list "stats"))
      (:export
       (unless (and id (not (string-empty-p (format "%s" id))))
         (signal 'etaf-weread-error '("export needs a book id")))
       (list "export" (format "%s" id) "--yes"))
      (_ (signal 'etaf-weread-error (list (format "Unknown request: %S" request)))))))

(defun etaf-weread--export-arguments (request)
  "Return extra arguments of REQUEST, currently only the export directory."
  (when (and (eq (plist-get request :op) :export)
             etaf-weread-export-directory)
    (list "--out" (expand-file-name etaf-weread-export-directory))))

(cl-defun etaf-weread--spawn (client program arguments callback)
  "Run PROGRAM with ARGUMENTS for CLIENT; deliver its decoded JSON to CALLBACK."
  (let* ((stdout (generate-new-buffer " *etaf-weread-stdout*"))
         (stderr (generate-new-buffer " *etaf-weread-stderr*"))
         (pending (etaf-weread--pending-create :stdout stdout :stderr stderr))
         (timeout (etaf-weread--client-timeout client)))
    (condition-case error
        (setf (etaf-weread--pending-process pending)
              (make-process
               :name "etaf-weread"
               :buffer stdout
               :stderr stderr
               :command (cons program arguments)
               :connection-type 'pipe
               :noquery t
               :coding 'utf-8-unix))
      (error
       (kill-buffer stdout)
       (kill-buffer stderr)
       (funcall callback (list :error (error-message-string error)))
       (cl-return-from etaf-weread--spawn nil)))
    (push pending (etaf-weread--client-pending client))
    (setf (etaf-weread--pending-timer pending)
          (run-at-time
           timeout nil
           (lambda ()
             (setf (etaf-weread--pending-cancelled pending) t)
             (when-let* ((process (etaf-weread--pending-process pending)))
               (when (process-live-p process) (delete-process process)))
             (setf (etaf-weread--client-pending client)
                   (delq pending (etaf-weread--client-pending client)))
             (funcall callback
                      (list :error (format "Backend request timed out after %ss" timeout)
                            :hint (mapconcat #'identity (cons program arguments) " "))))))
    (set-process-sentinel
     (etaf-weread--pending-process pending)
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal failed))
         (etaf-weread--settle client pending process callback))))
    nil))

(defun etaf-weread--settle (client pending process callback)
  "Collect the result of PROCESS and finish PENDING for CLIENT.
The callback is skipped when the request was cancelled."
  (let ((stdout (etaf-weread--pending-stdout pending))
        (stderr (etaf-weread--pending-stderr pending))
        (cancelled (etaf-weread--pending-cancelled pending)))
    (when-let* ((timer (etaf-weread--pending-timer pending)))
      (cancel-timer timer))
    (setf (etaf-weread--client-pending client)
          (delq pending (etaf-weread--client-pending client)))
    (let ((output (with-current-buffer stdout (buffer-string)))
          (errors (with-current-buffer stderr (buffer-string)))
          (status (process-exit-status process)))
      (kill-buffer stdout)
      (kill-buffer stderr)
      (unless cancelled
        (funcall callback
                 (if (and (eq (process-status process) 'exit) (zerop status))
                     (let ((data (etaf-weread--decode output)))
                       (cond ((null data) (list :error "Backend returned no data"
                                                :hint (string-trim errors)))
                             ((eq (plist-get data :ok) :false)
                              (etaf-weread--failure data errors))
                             (t (list :ok data))))
                   (let ((data (etaf-weread--decode output)))
                     (if data
                         (etaf-weread--failure data errors)
                       (list :error (format "Backend command failed (exit %s)" status)
                             :hint (string-trim errors))))))))))

(defun etaf-weread--failure (data errors)
  "Return an (:error ...) result built from backend DATA and ERRORS.
The skill's `message' is the human sentence; `error' is its stable code and is
only used when the message is missing."
  (let ((message (or (plist-get data :message)
                     (plist-get data :error)
                     (plist-get data :conclusion)
                     "Backend request failed"))
        (hint (or (plist-get data :hint) (string-trim errors))))
    (append (list :error (if (stringp message) message (format "%s" message)))
            (when (and hint (not (string-empty-p hint))) (list :hint hint)))))

(defun etaf-weread--decode (output)
  "Decode the first JSON object in OUTPUT, or nil."
  (when (and output (not (string-empty-p (string-trim output))))
    (condition-case nil
        (json-parse-string (string-trim output)
                           :object-type 'plist
                           :array-type 'list
                           :null-object nil
                           :false-object :false)
      (error nil))))

(provide 'etaf-weread-service)
;;; etaf-weread-service.el ends here
