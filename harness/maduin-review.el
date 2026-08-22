;;; maduin-review.el --- per-epic drift-review gate (Odin)  -*- lexical-binding: t; -*-

;;; Commentary:

;; Per-epic drift review.  Land first; when an epic's last child task
;; lands and closes (all children closed), an on-demand reviewer
;; session (Odin: slugineer-reviewer) runs once for THAT epic: it
;; compares the epic's full change set (diff from the recorded start of
;; its task group to HEAD) against the epic's goal (--design/--acceptance)
;; and emits a single verdict line:
;;
;;     REVIEW: APPROVED        (goal met)
;;     REVIEW: DRIFT <feedback> (goal not met)
;;
;; APPROVED → the epic is closed (goal met).  DRIFT → a P1 drift-fix task
;; is created under the epic and the epic stays open.
;;
;; The gate is wired into the dispatcher, not run inline:
;;
;;   dispatch closes wave's last task → `maduin-review-due-epic'
;;     → `maduin-dispatch-review' spawns a `reviewer' role session
;;     → `maduin-review-complete' parses its verdict on completion
;;
;; While a review is in flight, and while any drift-fix bead is still
;; open, `maduin-review-hold-with-p' holds the fleet: workers dispatch
;; the drift-fix rework first and pick up no other ticket until the gate
;; is clear.  `max-retries' bounds re-reviews of a repeatedly drifting
;; epic.  `maduin-review-gate' remains the synchronous single-call form
;; (spawn, wait, verdict) for direct/manual use.
;;
;; Deterministic gating (per-epic start, diff, blocking, verdict
;; parsing) stays in elisp here.  The reviewer only supplies the
;; verdict marker.  The old batched checkpoint (:start-sha/:landed) and
;; batch-size trigger are deprecated.

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

;;; Per-epic diff start

(defvar maduin-review--epic-starts nil
  "Alist ((EPIC-ID . START-SHA) ...) of per-epic diff start SHAs.
START-SHA is the main HEAD recorded at the first land of a child of
EPIC-ID (the pre-land parent of the first `land' merge commit).
Kept in memory for the lifetime of the pipeline process; later lands
keep the original start so the epic diff spans its full change set.")

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

(defvar maduin-review--epic-children-fn #'maduin-bd-epic-children
  "Function `(epic)' → list of child id strings (any status, incl. closed).
Distinct from `maduin-review--query-fn' because epic-completion checks
must see closed children; `bd query' excludes them unless `--all'.")

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

;;; Per-epic operations

(defun maduin-review--note-epic-land (epic-id)
  "Record the per-epic diff start for EPIC-ID on its first land.
After a land merge, HEAD~1 is the pre-land main state; record it the
first time a child of EPIC-ID lands (later lands keep the original
start).  Return t when a new start was recorded, nil when already
known or git failed."
  (if (assoc epic-id maduin-review--epic-starts)
      nil
    (let* ((root (funcall maduin-review--main-root-fn))
           (res (funcall maduin-review--git-output-fn root "rev-parse" "HEAD~1")))
      (if (and res (= 0 (car res)))
          (progn
            (push (cons epic-id (string-trim (cdr res)))
                  maduin-review--epic-starts)
            t)
        nil))))

(defun maduin-review--epic-diff (epic-id)
  "Return EPIC-ID's full change set `git diff START..HEAD', or nil.
START is the recorded per-epic start; when missing (e.g. after a
pipeline restart) fall back to the last land's parent (HEAD~1) and log
a warning."
  (let* ((start (or (cdr (assoc epic-id maduin-review--epic-starts))
                    (progn
                      (maduin-review--log
                       "epic %s: no recorded start SHA; diff limited to last land"
                       epic-id)
                      "HEAD~1")))
         (root (funcall maduin-review--main-root-fn))
         (res (funcall maduin-review--git-output-fn
                       root "diff" (concat start "..HEAD"))))
    (and res (= 0 (car res)) (cdr res))))

(defun maduin-review--epic-children-closed-p (epic-id)
  "Return t when every child task of EPIC-ID is closed.
An epic with no children is NOT complete (nil)."
  (let ((children (funcall maduin-review--epic-children-fn epic-id)))
    (and children
         (cl-every (lambda (id)
                     (let ((spec (condition-case nil
                                     (funcall maduin-review--show-fn id)
                                   (error nil))))
                       (string= (or (plist-get spec :status) "") "closed")))
                   children))))

(defun maduin-review--maybe-review-epic (task-id)
  "Run the per-epic review gate when closing TASK-ID completes its epic.
Resolve TASK-ID's parent epic; when all children of that epic are now
closed, record the epic's diff start if new, then run Odin once for
the epic.  Return the gate verdict, or nil when the task has no epic,
the epic is not complete, or review is disabled."
  (let* ((spec (condition-case nil
                   (funcall maduin-review--show-fn task-id)
                 (error nil)))
         (epic (and spec (plist-get spec :parent))))
    (when (and epic (maduin-review--epic-children-closed-p epic))
      (maduin-review--note-epic-land epic)
      (maduin-review-gate epic))))

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

(defvar maduin-review--in-flight nil
  "Alist ((SID . EPIC-ID) ...) of reviewer sessions currently running.
Populated by the dispatcher (`maduin-review-note-session') so the fleet
hold and the verdict handler share one source of truth.")

(defvar maduin-review--attempts nil
  "Alist ((EPIC-ID . COUNT) ...) of review attempts started per epic.
Bounded by the reviewer section's `max-retries': an epic that keeps
drifting stops re-reviewing instead of looping forever.")

(defvar maduin-review--exhausted nil
  "Epic IDs already reported as having exhausted their review retries.")

(defun maduin-review-max-retries ()
  "Return the reviewer's configured retry budget (default 3)."
  (let ((value (maduin-review--config-get 'max-retries 3)))
    (if (and (integerp value) (> value 0)) value 3)))

(defun maduin-review-in-flight-p ()
  "Return non-nil while any reviewer session is running."
  (not (null maduin-review--in-flight)))

(defun maduin-review-drift-fix-tasks ()
  "Return non-closed drift-fix task IDs, or nil.
`bd query' excludes closed issues by default, so an open or in-progress
drift-fix bead is exactly what holds the fleet."
  (and (maduin-review--enabled-p)
       (funcall maduin-review--query-fn "label=drift-fix")))

(defun maduin-review-hold-with-p (drift-fix-tasks)
  "Return non-nil when the fleet must not consume ordinary tickets.
The fleet is held while a review is in flight and while any drift-fix
bead is still open: the rework the reviewer asked for comes first.
DRIFT-FIX-TASKS is an already-fetched id list (nil means none), keeping
this predicate free of bd I/O on the run-loop's hot path."
  (and (maduin-review--enabled-p)
       (or (maduin-review-in-flight-p)
           (not (null drift-fix-tasks)))))

(defun maduin-review-hold-p ()
  "Return non-nil when the fleet must hold, querying bd for drift-fix work."
  (maduin-review-hold-with-p (maduin-review-drift-fix-tasks)))

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

;;; Epic goal context

(defun maduin-review--design-acceptance (id)
  "Return the DESIGN/ACCEPTANCE section text from `bd show ID', or nil.
This is the epic's goal: its --design/--acceptance as set at creation.
`bd show --json' does not expose design, so parse the human-readable
output from the DESIGN section header onward."
  (let ((res (funcall maduin-review--run-fn
                      (format "bd show %s" (shell-quote-argument id)))))
    (and res (= 0 (car res))
         (let ((out (cdr res)))
           (and (string-match "DESIGN[ \t]*\n" out)
                (substring out (match-beginning 0)))))))

;;; Reviewer plan + wait

(defun maduin-review--plan (diff context)
  "Build the Odin reviewer plan from EPIC-DIFF and goal CONTEXT.
CONTEXT is the epic's goal (its --design/--acceptance section)."
  (format
   (concat
    "You are Odin, the drift reviewer. An epic's task group has fully "
    "landed and merged to main. Compare the merged diff below against "
    "the epic's goal (design + acceptance criteria). Emit exactly one "
    "verdict line and stop:\n\n"
    "REVIEW: APPROVED\n"
    "or\n"
    "REVIEW: DRIFT <feedback...>\n\n"
    "APPROVED = the epic's goal is met. DRIFT = goal not met; the "
    "feedback must say why and what to fix.\n\n"
    "Epic diff:\n```\n%s\n```\n\n"
    "Epic goal (design/acceptance):\n```\n%s\n```\n")
   (or diff "") (or context "")))

(defun maduin-review-plan-for (epic-id)
  "Return the reviewer plan string for EPIC-ID (diff + goal context)."
  (maduin-review--plan (maduin-review--epic-diff epic-id)
                       (or (maduin-review--design-acceptance epic-id) "")))

(defun maduin-review--attempt-count (epic-id)
  "Return the number of reviews already started for EPIC-ID."
  (or (cdr (assoc epic-id maduin-review--attempts)) 0))

(defun maduin-review--retries-exhausted (epic-id)
  "Report EPIC-ID's exhausted review budget once, then return nil.
Returning nil lets callers use this in a conditional tail position: a
drifting epic stops re-reviewing and waits for a human instead."
  (unless (member epic-id maduin-review--exhausted)
    (push epic-id maduin-review--exhausted)
    (funcall maduin-review--comment-fn
             epic-id
             (format "review gate: %d review attempts exhausted — needs human attention"
                     (maduin-review-max-retries))))
  nil)

(defun maduin-review-due-epic (task-id)
  "Return TASK-ID's parent epic when it is now due for review, else nil.
Due = review enabled, the task has a parent epic, every child of that
epic is closed, no review is already in flight for it, and the epic has
review attempts left.  Records the epic's diff start as a side effect so
the reviewer sees the group's full change set."
  (when (maduin-review--enabled-p)
    (let* ((spec (condition-case nil
                     (funcall maduin-review--show-fn task-id)
                   (error nil)))
           (epic (and spec (plist-get spec :parent))))
      (when (and epic
                 (not (rassoc epic maduin-review--in-flight))
                 (maduin-review--epic-children-closed-p epic))
        (if (>= (maduin-review--attempt-count epic) (maduin-review-max-retries))
            (maduin-review--retries-exhausted epic)
          (maduin-review--note-epic-land epic)
          epic)))))

(defun maduin-review-note-session (sid epic-id)
  "Record reviewer session SID as reviewing EPIC-ID and count the attempt."
  (push (cons sid epic-id) maduin-review--in-flight)
  (let ((cell (assoc epic-id maduin-review--attempts)))
    (if cell
        (setcdr cell (1+ (cdr cell)))
      (push (cons epic-id 1) maduin-review--attempts)))
  epic-id)

(defun maduin-review--drop-session (sid)
  "Forget reviewer session SID and return the epic it was reviewing, or nil."
  (let ((epic (cdr (assoc sid maduin-review--in-flight))))
    (setq maduin-review--in-flight
          (cl-remove-if (lambda (entry) (equal (car entry) sid))
                        maduin-review--in-flight))
    epic))

(defun maduin-review-complete (sid output)
  "Finish reviewer session SID by parsing OUTPUT and acting on its verdict.
Return the verdict symbol from `maduin-review--dispatch-verdict', or nil
when SID was not a tracked reviewer session.  The session is always
dropped from the in-flight set, so a hold can never outlive its review."
  (let ((epic (maduin-review--drop-session sid)))
    (when epic
      (maduin-review--dispatch-verdict (maduin-review--verdict output) epic))))

(defun maduin-review-abort (sid reason)
  "Drop reviewer session SID after a failure and comment REASON on its epic.
Return the epic id, or nil when SID was not tracked."
  (let ((epic (maduin-review--drop-session sid)))
    (when epic
      (funcall maduin-review--comment-fn
               epic (format "review gate: %s" reason))
      epic)))

(defun maduin-review-reset ()
  "Clear all review gate runtime state (in-flight, attempts, epic starts)."
  (setq maduin-review--in-flight nil
        maduin-review--attempts nil
        maduin-review--exhausted nil
        maduin-review--epic-starts nil))

(defun maduin-review--wait (sid)
  "Block until reviewer session SID reaches a terminal state.
Return the terminal status (`completed' or `failed')."
  (let ((status (funcall maduin-review--complete-p-fn sid)))
    (while (eq status 'running)
      (sit-for 0.5)
      (setq status (funcall maduin-review--complete-p-fn sid)))
    status))

;;; Verdict dispatch

(defun maduin-review--close-epic (epic-id)
  "Close EPIC-ID with the review approval reason (goal met).
Log and continue on failure — the epic stays open then."
  (let ((res (funcall maduin-review--run-fn
                      (format "bd close %s --reason %s"
                              (shell-quote-argument epic-id)
                              (shell-quote-argument
                               "review gate: goal met (Odin approved)")))))
    (unless (and res (= 0 (car res)))
      (maduin-review--log "epic close failed (exit %s): %s"
                          (and res (car res)) (and res (cdr res))))))

(defun maduin-review--drop-epic-start (epic-id)
  "Forget EPIC-ID's recorded diff start (after the epic closes)."
  (setq maduin-review--epic-starts
        (cl-remove-if (lambda (entry)
                        (string= (car entry) epic-id))
                      maduin-review--epic-starts)))

(defun maduin-review--dispatch-verdict (verdict epic-id)
  "Handle VERDICT from `maduin-review--verdict' for EPIC-ID.
Return `approved' (epic closed, goal met), `drift' (drift-fix task +
comments, epic stays open) or `error' (comment; never silent-fail)."
  (pcase verdict
    ('approved
     (maduin-review--close-epic epic-id)
     (maduin-review--drop-epic-start epic-id)
     (setq maduin-review--attempts
           (cl-remove-if (lambda (entry) (equal (car entry) epic-id))
                         maduin-review--attempts)
           maduin-review--exhausted
           (delete epic-id maduin-review--exhausted))
     'approved)
    (`(drift . ,feedback)
     (let ((task (maduin-review--create-drift-fix feedback epic-id)))
       (when task
         (funcall maduin-review--comment-fn
                  task (format "drift detected by review gate: %s" feedback)))
       (funcall maduin-review--comment-fn
                epic-id (format "drift detected by review gate: %s" feedback))
       'drift))
    (_
     (funcall maduin-review--comment-fn
              epic-id "review gate: no verdict marker in reviewer output (error)")
     'error)))

;;; Gate

(defun maduin-review-gate (epic-id)
  "Run the per-epic drift-review gate (Odin) for EPIC-ID.
Gather the epic's full change set (recorded start .. HEAD) plus its
design/acceptance goal, spawn a reviewer session
(`(maduin-session-run root model agent plan)'), wait for completion,
read its output and parse the verdict.

EPIC-ID is required — it is the review subject: its --design/--acceptance
is the goal context and its recorded start bounds the diff.

Return:
  `approved'  → goal met; EPIC-ID closed, recorded start dropped
  `drift'     → goal not met; drift-fix task created + comments; EPIC-ID open
  `error'     → comment on EPIC-ID; stays open (never silent-fail)
  nil         → review disabled"
  (if (not (maduin-review--enabled-p))
      nil
    (let* ((root (funcall maduin-review--main-root-fn))
           (plan (maduin-review-plan-for epic-id))
           (model (or (maduin-review--config-get
                       'model "opencode-go/deepseek-v4-pro")
                      "opencode-go/deepseek-v4-pro"))
           (agent (or (maduin-review--config-get 'agent "slugineer-reviewer")
                      "slugineer-reviewer"))
           (sid (funcall maduin-review--session-run-fn root model agent plan)))
      (if (not sid)
          (progn
            (funcall maduin-review--comment-fn
                     epic-id "review gate: failed to spawn reviewer session (error)")
            'error)
        (let ((status (maduin-review--wait sid))
              (output (funcall maduin-review--session-output-fn sid)))
          (unless (eq status 'completed)
            (maduin-review--log "reviewer session status: %s" status))
          (maduin-review--dispatch-verdict
           (maduin-review--verdict output) epic-id))))))

(provide 'maduin-review)

;;; maduin-review.el ends here
