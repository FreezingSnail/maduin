;;; maduin-pipeline.el --- concierge/designer/implementer pipeline  -*- lexical-binding: t; -*-

;;; Commentary:

;; Producer/consumer core.  Concierge/designer agents produce bd tasks;
;; implementer (fleet) agents consume them.  Fleet polling runs on
;; `run-at-time' timers, dispatching ready bd tasks to implementer
;; seats.  Concierge dispatch sends prompts to free concierge agents.

;;; Code:

(defconst maduin-pipeline--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-pipeline.el.")

(add-to-list 'load-path maduin-pipeline--dir)

(require 'cl-lib)
(require 'maduin-bd-bridge)
(require 'maduin-agent)
(require 'maduin-session)
(require 'maduin-config)
(require 'maduin-workspace)

;; resolver may not exist when pipeline is loaded standalone.
(condition-case nil
    (require 'maduin-resolver)
  (error nil))

(defvar maduin-pipeline-timers nil
  "Alist ((SEAT-NAME . TIMER) ...) of active fleet polling timers.")

;;; Config access

(defun maduin-pipeline--config ()
  "Return the maduin config alist.
Load harness/config.el explicitly because maduin-config.el
is a stub and the real values live there."
  (or (bound-and-true-p maduin-config)
      (condition-case nil
          (progn
            (load-file (expand-file-name "config.el" maduin-pipeline--dir))
            (bound-and-true-p maduin-config))
        (error nil))))

(defun maduin-pipeline--config-section (section)
  "Return alist for SECTION of maduin config, or nil."
  (cdr (assq section (maduin-pipeline--config))))

(defun maduin-pipeline--config-get (section key)
  "Return value of KEY in SECTION of maduin config, or nil."
  (cdr (assq key (maduin-pipeline--config-section section))))

;;; Seats

(defun maduin-pipeline-fleet-seats ()
  "Return list of fleet seat names from config."
  (delq nil
        (mapcar (lambda (s)
                  (when (listp s) (alist-get 'name s)))
                (maduin-pipeline--config-get 'fleet 'seats))))

(defun maduin-pipeline--concierge-seats ()
  "Return list of concierge seat names from config."
  (delq nil
        (mapcar (lambda (s)
                  (when (listp s) (alist-get 'name s)))
                (maduin-pipeline--config-get 'concierge 'seats))))

(defun maduin-pipeline--designer-seats ()
  "Return list of designer seat names from config."
  (delq nil
        (mapcar (lambda (s)
                  (when (listp s) (alist-get 'name s)))
                (maduin-pipeline--config-get 'designer 'seats))))

(defun maduin-pipeline--seat-model (seat-name)
  "Return model configured for fleet SEAT-NAME, or \"default\"."
  (let ((seats (maduin-pipeline--config-get 'fleet 'seats)))
    (or (and (listp seats)
             (let ((entry (cl-find-if
                           (lambda (s) (string= (alist-get 'name s) seat-name))
                           seats)))
               (and entry (alist-get 'model entry))))
        "default")))

(defun maduin-pipeline-find-free-agent (role)
  "Return first free seat name for ROLE, or nil.
ROLE is \"concierge\", \"designer\" or \"implementer\".  Free means
session alive and status not `working'."
  (let ((seats (cond
                ((string= role "implementer") (maduin-pipeline-fleet-seats))
                ((string= role "designer") (maduin-pipeline--designer-seats))
                (t (maduin-pipeline--concierge-seats)))))
    (cl-find-if
     (lambda (seat)
       (and (maduin-session-alive-p seat)
            (let ((st (maduin-agent-status seat)))
              (not (eq (plist-get st :status) 'working)))))
     seats)))

;;; Fleet polling

(defun maduin-pipeline--git (dir &rest args)
  "Run `git -C DIR ARGS...' via shell; return exit status.
Output is discarded.  Uses `call-process-shell-command' so the
exit status is available programmatically."
  (let ((default-directory dir)
        (cmd (format "git -C %s %s"
                     (shell-quote-argument dir)
                     (mapconcat #'shell-quote-argument args " "))))
    (call-process-shell-command cmd nil nil)))

(defun maduin-pipeline--main-root ()
  "Return main maduin repo root.
Prefer the directory containing maduin.el, else
`default-directory'."
  (or (and (locate-library "maduin")
           (file-name-directory (locate-library "maduin")))
      (expand-file-name default-directory)))

(defun maduin-pipeline--git-output (dir &rest args)
  "Run `git -C DIR ARGS...'; return (STATUS . OUTPUT)."
  (let* ((default-directory dir)
         (cmd (format "git -C %s %s"
                      (shell-quote-argument dir)
                      (mapconcat #'shell-quote-argument args " ")))
         (buf (get-buffer-create " *maduin-pipeline-git*")))
    (with-current-buffer buf (erase-buffer))
    (cons (call-process-shell-command cmd nil buf)
          (with-current-buffer buf (buffer-string)))))

(defun maduin-pipeline-land-branch (seat-name)
  "Commit SEAT-NAME worktree changes and merge its branch into main.
Return t on successful merge, \\='conflict when the merge failed and
output indicates a conflict, nil on other failures (missing worktree,
commit failure, non-conflict merge failure; logged, never forced).
Steps: add -A in worktree; commit if staged (t if nothing to land);
then `git merge --no-ff' the seat branch from the main repo."
  (let* ((wt (maduin-workspace-path seat-name))
         (branch (maduin-workspace-branch seat-name))
         (main (maduin-pipeline--main-root)))
    (if (not (file-directory-p wt))
        (progn
          (maduin-workspace--log-warning
           (format "land-branch: worktree %s missing for seat %s" wt seat-name))
          nil)
      (maduin-pipeline--git wt "add" "-A")
      (if (= 0 (maduin-pipeline--git wt "diff" "--cached" "--quiet"))
          ;; Nothing staged — nothing to land.
          t
        (let ((res (maduin-pipeline--git-output
                    wt "commit" "-m"
                    (format "task complete (%s)" seat-name))))
          (if (and (/= 0 (car res))
                   (not (string-match-p "nothing to commit" (cdr res))))
              (progn
                (maduin-workspace--log-warning
                 (format "land-branch: commit failed (exit %d): %s"
                         (car res) (cdr res)))
                nil)
            (let ((res (maduin-pipeline--git-output
                        main "merge" "--no-ff" branch
                        "-m" (format "land %s" seat-name))))
              (if (= 0 (car res))
                  t
                ;; Distinguish conflict from other merge failures:
                ;; git prints "CONFLICT (content): ..." / "fix conflicts".
                (if (string-match-p "conflict" (downcase (cdr res)))
                    'conflict
                   (maduin-workspace--log-warning
                    (format "land-branch: merge of %s into main failed (exit %d): %s"
                            branch (car res) (cdr res)))
                   nil)))))))))

(defun maduin-pipeline-start-fleet (seat-name)
  "Start fleet polling timer for SEAT-NAME.  Return the timer.
Repeats every `fleet.poll-interval' from config (default 30s)."
  (let* ((interval (or (maduin-pipeline--config-get 'fleet 'poll-interval) 30))
         (old (cdr (assoc seat-name maduin-pipeline-timers)))
         (timer (run-at-time interval interval
                             #'maduin-pipeline--poll seat-name)))
    (when old (cancel-timer old))
    (setq maduin-pipeline-timers
          (cons (cons seat-name timer)
                (assq-delete-all seat-name maduin-pipeline-timers)))
    timer))

(defun maduin-pipeline-stop-fleet (seat-name)
  "Cancel fleet polling timer for SEAT-NAME."
  (let ((entry (assoc seat-name maduin-pipeline-timers)))
    (when entry
      (cancel-timer (cdr entry))
      (setq maduin-pipeline-timers
            (assq-delete-all seat-name maduin-pipeline-timers)))))

(defun maduin-pipeline--last-output ()
  "Return last 8192 chars of current buffer, stripped of text props."
  (buffer-substring-no-properties
   (max (point-min) (- (point-max) 8192))
   (point-max)))

(defun maduin-pipeline--poll (seat-name)
  "Poll for a ready bd task and dispatch to fleet SEAT-NAME.
Skip when SEAT-NAME is already working.  On agent exit, land the
branch first, then close the task only on successful land; on
conflict or other failure leave the task open, and mark the seat idle."
  (let ((status (maduin-agent-status seat-name)))
    (unless (and status (eq (plist-get status :status) 'working))
      (let ((task (car (maduin-bd-ready-tasks))))
        (when task
          (maduin-bd-claim task)
          (let* ((model (maduin-pipeline--seat-model seat-name))
                 (workdir (expand-file-name
                           (or (maduin-pipeline--config-get 'workspaces 'path)
                               "harness/workspaces")))
                  (proc (maduin-agent-spawn
                         seat-name "implementer" model workdir)))
            (if (not proc)
                (message "maduin: spawn %s failed for task %s"
                         seat-name task)
              (let ((buf (process-buffer proc)))
                (when buf
                  (with-current-buffer buf
                    (setq-local maduin-current-task task)
                    (setq-local maduin-status 'working)))
                ;; Feed the plan: fetch task spec, send into worker process.
                (when (process-live-p proc)
                  (let* ((spec (condition-case nil
                                   (maduin-bd-show task)
                                 (error nil)))
                         (instr
                          (format
                           "Implement bd task %s.\n\nTitle: %s\n\nDescription:\n%s\n\n\
Write output.md describing what you changed. Commit your work to this \
branch when done. If blocked, explain why — do not invent work."
                           task
                           (if (plist-get spec :title) (plist-get spec :title) "?")
                           (if (plist-get spec :desc) (plist-get spec :desc) "?"))))
                    (process-send-string proc instr)))
                (set-process-sentinel
                 proc
                 (lambda (p _event)
                   (when (eq (process-status p) 'exit)
                     (let* ((pbuf (process-buffer p))
                            (output (when (buffer-live-p pbuf)
                                      (with-current-buffer pbuf
                                        (maduin-pipeline--last-output))))
                            (land (condition-case err
                                      (maduin-pipeline-land-branch seat-name)
                                    (error
                                     (maduin-workspace--log-warning
                                      (format "land-branch failed for seat %s: %s"
                                              seat-name (error-message-string err)))
                                     nil))))
                       (cond
                        ((eq land t)
                         ;; Landed — close the task now.
                         (maduin-bd-close task output))
                        ((eq land 'conflict)
                         (maduin-bd--run
                          (format "bd comment %s %s"
                                  (shell-quote-argument task)
                                  (shell-quote-argument
                                   "merge conflict — resolver dispatched")))
                         (unless (maduin-resolver-active-p seat-name)
                           (maduin-resolver-start seat-name))
                         (maduin-resolver-register seat-name task)
                         (maduin-workspace--log-warning
                          (format "land-branch: conflict for seat %s task %s; resolver dispatched"
                                  seat-name task))
                         'conflict)
                        (t
                         ;; Other land failure — never close.
                         (maduin-bd--run
                          (format "bd comment %s %s"
                                  (shell-quote-argument task)
                                  (shell-quote-argument
                                   "land failed — task left open")))
                         (maduin-workspace--log-warning
                          (format "land-branch: failure for seat %s task %s; left open"
                                  seat-name task))
                         nil))
                       (when (buffer-live-p pbuf)
                         (with-current-buffer pbuf
                           (setq-local maduin-current-task nil)
                           (setq-local maduin-status 'idle)))))))))))))))

;;; Concierge dispatch

(defun maduin-pipeline-dispatch-concierge (prompt)
  "Send PROMPT to first free concierge agent.
Warn when no concierge agent is free."
  (let ((seat (maduin-pipeline-find-free-agent "concierge")))
    (if seat
        (let* ((buf (maduin-session--buffer seat))
               (proc (and buf (get-buffer-process buf))))
          (if (and proc (process-live-p proc))
              (process-send-string proc prompt)
            (when buf
              (with-current-buffer buf
                (let ((inhibit-read-only t))
                  (goto-char (point-max))
                  (insert prompt))))))
      (message "maduin: no free concierge agent; prompt undelivered"))))

;;; Review (placeholder for v0.2)

(defun maduin-pipeline-review (task-id)
  "Placeholder review of TASK-ID: message and remember.
Full review gate lands in v0.2."
  (message "maduin: reviewing %s" task-id)
  (maduin-bd-remember (format "reviewed %s" task-id)))

;;; Status

(defun maduin-pipeline--count (status)
  "Return bd issue count with STATUS via `bd count', or 0."
  (let* ((res (maduin-bd--run
               (format "bd count --status %s --json" status)))
         (data (and (= 0 (car res))
                    (maduin-bd--json-data (cdr res)))))
    (or (and data (alist-get 'count (car data))) 0)))

(defun maduin-pipeline-status ()
  "Return plist (:queued :active :completed :blocked :fleet-free :fleet-busy)."
  (let* ((fleet (maduin-pipeline-fleet-seats))
         (busy (cl-count-if
                (lambda (s)
                  (eq (plist-get (maduin-agent-status s) :status) 'working))
                fleet)))
    (list :queued (length (or (maduin-bd-ready-tasks) nil))
          :active (maduin-pipeline--count "in-progress")
          :completed (maduin-pipeline--count "closed")
          :blocked (maduin-pipeline--count "blocked")
          :fleet-free (- (length fleet) busy)
          :fleet-busy busy)))

(provide 'maduin-pipeline)

;;; maduin-pipeline.el ends here
