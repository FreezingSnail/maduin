;;; maduin-review.el --- batched drift-review gate (Odin)  -*- lexical-binding: t; -*-

;;; Commentary:

;; Post-merge drift review.  Land first; after a batch of N tasks lands
;; (or an epic's task group completes), an on-demand reviewer session
;; (Odin: slugineer-reviewer) compares the merged diff against the
;; group's design + acceptance and emits a single verdict line:
;;
;;     REVIEW: APPROVED
;;     REVIEW: DRIFT <feedback...>
;;
;; Deterministic gating (checkpoint, diff, blocking, verdict parsing)
;; stays in elisp here.  The reviewer only supplies the verdict marker.

;;; Code:

(require 'cl-lib)

(defconst maduin-review--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-review.el.")

(add-to-list 'load-path maduin-review--dir)

(require 'maduin-config)
(require 'maduin-bd-bridge)

;; Optional substrate deps: guarded so this file byte-compiles and loads
;; standalone (e.g. `emacs --batch -Q -L harness -l harness/maduin-review.el').
(require 'maduin-session nil t)
(require 'maduin-pipeline nil t)

;;; Checkpoint

(defvar maduin-review--checkpoint nil
  "Plist (:start-sha :landed) for the current review batch.
:start-sha is the main HEAD SHA recorded at the start of the batch;
:landed is the count of tasks landed since then.")

;;; Logging

(defun maduin-review--log (fmt &rest args)
  "Log a review-gate message."
  (message "[maduin-review] %s" (apply #'format fmt args)))

;;; Git plumbing

(defun maduin-review--main-root ()
  "Return the main maduin repo root directory.
Prefer `maduin-pipeline--main-root' when available, else the cwd."
  (or (and (fboundp 'maduin-pipeline--main-root)
           (maduin-pipeline--main-root))
      (expand-file-name default-directory)))

(defun maduin-review--git-output (dir &rest args)
  "Run `git -C DIR ARGS...'; return (STATUS . OUTPUT).
Reuse `maduin-pipeline--git-output' when available, else shell out."
  (if (fboundp 'maduin-pipeline--git-output)
      (apply #'maduin-pipeline--git-output dir args)
    (let* ((default-directory dir)
           (cmd (format "git -C %s %s"
                        (shell-quote-argument dir)
                        (mapconcat #'shell-quote-argument args " ")))
           (buf (get-buffer-create " *maduin-review-git*")))
      (with-current-buffer buf (erase-buffer))
      (cons (call-process-shell-command cmd nil buf)
            (with-current-buffer buf (buffer-string))))))

;;; Config access

(defun maduin-review--config-get (key default)
  "Return reviewer-section KEY from `maduin-config', or DEFAULT.
Honor explicit nil values; fall back only when KEY is absent."
  (let* ((section (and (boundp 'maduin-config)
                       (cdr (assq 'reviewer maduin-config))))
         (cell (and section (assq key section))))
    (if cell (cdr cell) default)))

(defun maduin-review--enabled-p ()
  "Return non-nil when the review gate is enabled in config."
  (maduin-review--config-get 'enabled t))

;;; Session output reader

(defun maduin-review--session-output (sid)
  "Return the raw output text of reviewer session SID, or nil.
Reads the session's hidden run buffer via `maduin-session--run-buffer'."
  (let ((buf (and (fboundp 'maduin-session--run-buffer)
                  (maduin-session--run-buffer sid))))
    (and buf (buffer-live-p buf)
         (with-current-buffer buf (buffer-string)))))

;;; Injection seams (function-valued defvars; tests let-bind these).

(defvar maduin-review--run-fn #'maduin-bd--run
  "Function `(cmd)' → (exit-code . output-string).")

(defvar maduin-review--show-fn #'maduin-bd-show
  "Function `(task)' → plist (:title :desc :status :deps) | nil.")

(defvar maduin-review--comment-fn #'maduin-bd-comment
  "Function `(id text)' → boolean.")

(defvar maduin-review--query-fn #'maduin-bd-query
  "Function `(q)' → list of issue ids | nil.")

(defvar maduin-review--session-run-fn #'maduin-session-run
  "Function `(workdir model agent plan)' → session handle | nil.")

(defvar maduin-review--complete-p-fn #'maduin-session-complete-p
  "Function `(sid)' → `completed' | `running' | `failed'.")

(defvar maduin-review--session-output-fn #'maduin-review--session-output
  "Function `(sid)' → raw output text | nil.")

(defvar maduin-review--git-output-fn #'maduin-review--git-output
  "Function `(dir &rest args)' → (STATUS . OUTPUT).")

(defvar maduin-review--main-root-fn #'maduin-review--main-root
  "Function `()' → main repo root directory string.")

;;; Checkpoint operations

(defun maduin-review--mark-start ()
  "Record current main HEAD SHA as :start-sha and reset :landed to 0.
Return the checkpoint plist on success, nil when git fails."
  (let* ((root (funcall maduin-review--main-root-fn))
         (res (funcall maduin-review--git-output-fn root "rev-parse" "HEAD")))
    (if (and res (= 0 (car res)))
        (setq maduin-review--checkpoint
              (list :start-sha (string-trim (cdr res)) :landed 0))
      nil)))

(defun maduin-review--note-land ()
  "Increment :landed in the checkpoint.  Return t when the batch is full.
Return nil (no-op) when review is disabled or the checkpoint is missing."
  (when (and (maduin-review--enabled-p) maduin-review--checkpoint)
    (let* ((n (1+ (or (plist-get maduin-review--checkpoint :landed) 0)))
           (batch (or (maduin-review--config-get 'batch-size 3) 3)))
      (setq maduin-review--checkpoint
            (plist-put maduin-review--checkpoint :landed n))
      (>= n batch))))

(defun maduin-review--diff ()
  "Return the batch diff text `git diff <start-sha>..HEAD', or nil.
Requires a checkpoint with a non-nil :start-sha."
  (let ((start (and maduin-review--checkpoint
                    (plist-get maduin-review--checkpoint :start-sha))))
    (when start
      (let* ((root (funcall maduin-review--main-root-fn))
             (res (funcall maduin-review--git-output-fn
                           root "diff" (concat start "..HEAD"))))
        (and res (= 0 (car res)) (cdr res))))))

;;; Verdict parsing

(defun maduin-review--verdict (output)
  "Parse reviewer OUTPUT for the verdict marker.
Return `approved' for REVIEW: APPROVED; (cons `drift' FEEDBACK) for
REVIEW: DRIFT FEEDBACK (FEEDBACK = text after the marker on that line);
`error' when no marker is present."
  (cond
   ((not (stringp output)) 'error)
   ((string-match "REVIEW: APPROVED" output) 'approved)
   ((string-match "REVIEW: DRIFT" output)
    (let* ((start (match-end 0))
           (line-end (or (string-match "\n" output start) (length output)))
           (feedback (string-trim (substring output start line-end))))
      (cons 'drift feedback)))
   (t 'error)))

;;; Blocking gate

(defun maduin-review--blocked-p ()
  "Return t when an open drift-fix task exists (fleet blocked)."
  (and (maduin-review--enabled-p)
       (not (null (funcall maduin-review--query-fn
                           "status=open AND label=drift-fix")))))

;;; Drift-fix task creation

(defun maduin-review--short-feedback (feedback)
  "Return a short one-line summary of FEEDBACK for the task title."
  (let ((one (string-trim (replace-regexp-in-string "[\n\r\t]+" " " feedback))))
    (if (> (length one) 40)
        (concat (substring one 0 40) "…")
      one)))

(defun maduin-review--create-drift-fix (feedback &optional parent-id)
  "Create a high-priority (P1) drift-fix task for FEEDBACK.
PARENT-ID, when given, sets the parent epic (omitted when unknown).
Return the new task ID or nil."
  (let* ((short (maduin-review--short-feedback feedback))
         (title (format "drift-fix: %s" short))
         (cmd (format "bd create %s --type task --priority P1 --label drift-fix --silent --description %s%s"
                      (shell-quote-argument title)
                      (shell-quote-argument feedback)
                      (if parent-id
                          (format " --parent %s" (shell-quote-argument parent-id))
                        ""))))
    (let ((res (funcall maduin-review--run-fn cmd)))
      (if (and res (= 0 (car res)))
          (let ((id (string-trim (cdr res))))
            (if (string-empty-p id) nil id))
        (maduin-review--log "drift-fix create failed (exit %s): %s"
                            (and res (car res)) (and res (cdr res)))
        nil))))

;;; Landed-task design/acceptance context

(defun maduin-review--design-acceptance (id)
  "Return the DESIGN/ACCEPTANCE section text from `bd show ID', or nil.
`bd show --json' does not expose design, so parse the human-readable
output from the DESIGN section header onward."
  (let ((res (funcall maduin-review--run-fn
                      (format "bd show %s" (shell-quote-argument id)))))
    (and res (= 0 (car res))
         (let ((out (cdr res)))
           (and (string-match "DESIGN[ \t]*\n" out)
                (substring out (match-beginning 0)))))))

(defun maduin-review--landed-context ()
  "Gather design/acceptance context for landed tasks in the batch.
Query closed tasks, then for each build a block from `maduin-bd-show'
(title + description) plus the human-readable DESIGN/ACCEPTANCE section.
Return a string, or nil when no landed tasks are found."
  (let ((ids (funcall maduin-review--query-fn "status=closed AND type=task")))
    (when ids
      (mapconcat
       (lambda (id)
         (let ((spec (condition-case nil
                         (funcall maduin-review--show-fn id)
                       (error nil))))
           (format "== %s: %s ==\n%s\n%s"
                   id
                   (or (plist-get spec :title) "")
                   (or (plist-get spec :desc) "")
                   (or (maduin-review--design-acceptance id) ""))))
       ids "\n\n"))))

;;; Reviewer plan + wait

(defun maduin-review--plan (diff context)
  "Build the Odin reviewer plan from batch DIFF and design/acceptance CONTEXT."
  (format
   (concat
    "You are Odin, the drift reviewer. Compare the merged diff below "
    "against the group's design and acceptance criteria. Emit exactly one "
    "verdict line and stop:\n\n"
    "REVIEW: APPROVED\n"
    "or\n"
    "REVIEW: DRIFT <feedback...>\n\n"
    "Batch diff:\n```\n%s\n```\n\n"
    "Group design/acceptance:\n```\n%s\n```\n")
   (or diff "") (or context "")))

(defun maduin-review--wait (sid)
  "Block until reviewer session SID reaches a terminal state.
Return the terminal status (`completed' or `failed')."
  (let ((status (funcall maduin-review--complete-p-fn sid)))
    (while (eq status 'running)
      (sit-for 0.5)
      (setq status (funcall maduin-review--complete-p-fn sid)))
    status))

;;; Verdict dispatch

(defun maduin-review--dispatch-verdict (verdict epic-id)
  "Handle VERDICT from `maduin-review--verdict'.
EPIC-ID, when given, is the batch's parent epic (comment target).
Return `approved' (checkpoint reset), `drift' (drift-fix task + comment)
or `error' (comment; never silent-fail).  The checkpoint is NOT reset for
`drift' or `error'."
  (pcase verdict
    ('approved
     (maduin-review--mark-start)
     'approved)
    (`(drift . ,feedback)
     (let ((task (maduin-review--create-drift-fix feedback epic-id)))
       (when task
         (funcall maduin-review--comment-fn
                  task (format "drift detected by review gate: %s" feedback)))
       (when epic-id
         (funcall maduin-review--comment-fn
                  epic-id (format "drift detected by review gate: %s" feedback)))
       'drift))
    (_
     (if epic-id
         (funcall maduin-review--comment-fn
                  epic-id "review gate: no verdict marker in reviewer output (error)")
       (maduin-review--log "gate error: no verdict marker; no epic id to comment"))
     'error)))

;;; Gate

(defun maduin-review-gate (&optional epic-id)
  "Run the batched drift-review gate (Odin).
Mark the checkpoint start when empty, gather the batch diff plus the
landed tasks' design/acceptance, spawn a reviewer session
(`(maduin-session-run root model agent plan)'), wait for completion, read
its output and parse the verdict.

EPIC-ID, when given, is the batch's parent epic (used as drift-fix parent
and comment target).

Return:
  `approved'  → checkpoint reset (mark-start)
  `drift'     → drift-fix task created + comment; checkpoint NOT reset
  `error'     → comment; checkpoint NOT reset (never silent-fail)
  nil         → review disabled"
  (if (not (maduin-review--enabled-p))
      nil
    (when (or (null maduin-review--checkpoint)
              (null (plist-get maduin-review--checkpoint :start-sha)))
      (maduin-review--mark-start))
    (let* ((root (funcall maduin-review--main-root-fn))
           (diff (maduin-review--diff))
           (context (maduin-review--landed-context))
           (plan (maduin-review--plan diff context))
           (model (or (maduin-review--config-get
                       'model "opencode-go/deepseek-v4-pro")
                      "opencode-go/deepseek-v4-pro"))
           (agent (or (maduin-review--config-get 'agent "slugineer-reviewer")
                      "slugineer-reviewer"))
           (sid (funcall maduin-review--session-run-fn root model agent plan)))
      (if (not sid)
          (progn
            (if epic-id
                (funcall maduin-review--comment-fn
                         epic-id "review gate: failed to spawn reviewer session (error)")
              (maduin-review--log "gate error: failed to spawn reviewer session"))
            'error)
        (let ((status (maduin-review--wait sid))
              (output (funcall maduin-review--session-output-fn sid)))
          (unless (eq status 'completed)
            (maduin-review--log "reviewer session status: %s" status))
          (maduin-review--dispatch-verdict
           (maduin-review--verdict output) epic-id))))))

(provide 'maduin-review)

;;; maduin-review.el ends here
