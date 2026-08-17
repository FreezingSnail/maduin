;;; maduin-dispatch.el --- demand-driven ephemeral session dispatcher  -*- lexical-binding: t; -*-

;;; Commentary:

;; Deterministic job dispatcher.  Spawns and reaps autonomous LLM
;; sessions on demand; no persistent fleet processes, zero idle.
;;
;; Sessions (maduin-session.el `maduin-session-run') exist ONLY while a
;; unit of work is in flight.  Fleet count (3) is a *concurrency cap*,
;; not a process count: at most N implementer sessions run at once.
;;
;; Deterministic work — poll, claim, dispatch, land, close — is elisp
;; here.  The LLM is non-deterministic and runs only inside a spawned
;; session.  Land/close reuse maduin-pipeline as the single source of
;; truth (`maduin-pipeline-land-branch', `maduin-bd-close').
;;
;; Every subprocess-touching call is an overridable function-valued
;; defvar (an injection seam) so ERT tests can mock session-run,
;; land, close, claim, ready-tasks, show, comment, workdir and
;; session-delete without spawning a real opencode.

;;; Code:

(require 'cl-lib)

(defconst maduin-dispatch--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-dispatch.el.")

(add-to-list 'load-path maduin-dispatch--dir)

(require 'maduin-config)
(require 'maduin-session)
(require 'maduin-bd-bridge)
(require 'maduin-workspace)
(require 'maduin-pipeline)

;;; Injection seams (function-valued defvars; tests let-bind these).

(defvar maduin-dispatch--session-run-fn #'maduin-session-run
  "Function `(workdir model agent plan)' → session handle | nil.")

(defvar maduin-dispatch--session-delete-fn #'maduin-session-delete
  "Function `(sid)' → boolean.")

(defvar maduin-dispatch--diff-fn #'maduin-session-diff
  "Function `(sid)' → list of diff alists | nil.")

(defvar maduin-dispatch--land-fn #'maduin-pipeline-land-branch
  "Function `(seat)' → t | `conflict' | nil.")

(defvar maduin-dispatch--landed-fn #'maduin-pipeline-landed-p
  "Function `(seat)' → non-nil when the seat's branch tip is an ancestor
of main.")

(defvar maduin-dispatch--close-fn #'maduin-bd-close
  "Function `(task output &optional dir)' → boolean.
DIR is the seat worktree the close output should land in.")

(defvar maduin-dispatch--claim-fn #'maduin-bd-claim
  "Function `(task)' → boolean.")

(defvar maduin-dispatch--release-fn #'maduin-bd-release
  "Function `(task)' → boolean.  Releases a failed task's claim (status → open).")

(defvar maduin-dispatch--ready-fn #'maduin-bd-ready-tasks
  "Function `()' → list of ready task id strings | nil.")

(defvar maduin-dispatch--show-fn #'maduin-bd-show
  "Function `(task)' → plist (:title :desc :status :deps) | nil.")

(defvar maduin-dispatch--comment-fn #'maduin-bd-comment
  "Function `(id text)' → boolean.")

(defvar maduin-dispatch--workdir-fn #'maduin-dispatch--ensure-workdir
  "Function `(seat)' → worktree directory string.")

(defvar maduin-dispatch--open-epics-fn #'maduin-bd-open-epics
  "Function `()' → list of open epic id strings | nil.")

(defvar maduin-dispatch--in-progress-fn #'maduin-bd-in-progress-tasks
  "Function `()' → list of in_progress task id strings | nil.
Recovery seam: detects tasks orphaned by an Emacs quit mid-task.")

(defvar maduin-dispatch--epic-children-fn #'maduin-bd-epic-children
  "Function `(epic)' → list of child id strings | nil.")

(defvar maduin-dispatch--epic-decompose-fn #'maduin-designer-decompose-epic
  "Function `(epic)' → session handle | nil.
Reuses maduin-designer machinery (Ramuh decomposition session).")

(declare-function maduin-designer-decompose-epic "maduin-designer.el")

;;; Active-session registry (concurrency tracking).

(defvar maduin-dispatch--active nil
  "List of plists (:handle :seat :role :task) for in-flight sessions.
ROLE is a symbol: `implementer', `designer' or `repairer'.")

(defvar maduin-dispatch--timer nil
  "Run-loop timer, or nil when dispatchers are inactive.")

(defvar maduin-dispatch--draining nil
  "Non-nil while a soft stop is draining in-flight sessions.
The run-loop picks up no new work while draining.")

;;; Config access

(defun maduin-dispatch--config-section (section)
  "Return alist for SECTION of `maduin-config', or nil."
  (and (boundp 'maduin-config) maduin-config
       (cdr (assq section maduin-config))))

(defun maduin-dispatch--config-get (section key)
  "Return value of KEY in SECTION of maduin config, or nil."
  (cdr (assq key (maduin-dispatch--config-section section))))

(defun maduin-dispatch--seats (section)
  "Return list of seat names in SECTION of config."
  (delq nil
        (mapcar (lambda (s) (and (listp s) (alist-get 'name s)))
                (maduin-dispatch--config-get section 'seats))))

(defun maduin-dispatch--fleet-seats ()
  "Return list of implementer (fleet) seat names."
  (maduin-dispatch--seats 'fleet))

(defun maduin-dispatch--designer-seats ()
  "Return list of designer seat names."
  (maduin-dispatch--seats 'designer))

(defun maduin-dispatch--seat-model (section seat)
  "Return model for SEAT in SECTION, or \"default\"."
  (let* ((seats (maduin-dispatch--config-get section 'seats))
         (entry (and (listp seats)
                     (cl-find-if (lambda (s)
                                   (string= (alist-get 'name s) seat))
                                 seats))))
    (or (and entry (alist-get 'model entry)) "default")))

(defun maduin-dispatch--seat-model-for (role seat)
  "Return model for ROLE seat SEAT."
  (pcase role
    ('implementer (maduin-dispatch--seat-model 'fleet seat))
    ('designer (maduin-dispatch--seat-model 'designer seat))
    ('repairer (or (maduin-dispatch--config-get 'repairer 'model) "default"))
    (_ "default")))

(defun maduin-dispatch--seat-agent-for (role)
  "Return agent string for ROLE, or nil."
  (pcase role
    ('implementer (maduin-dispatch--config-get 'fleet 'agent))
    ('designer (maduin-dispatch--config-get 'designer 'agent))
    ('repairer (maduin-dispatch--config-get 'repairer 'agent))
    (_ nil)))

(defun maduin-dispatch--seat-fallback (role)
  "Return fallback model for ROLE, or nil.
Only the fleet (implementer) role has a fallback (free-flash → go flash)."
  (and (eq role 'implementer)
       (maduin-dispatch--config-get 'fleet 'fallback)))

;;; Concurrency

(defun maduin-dispatch--role-cap (role)
  "Return concurrency cap for ROLE (number of seats)."
  (pcase role
    ('implementer (length (maduin-dispatch--fleet-seats)))
    ('designer (length (maduin-dispatch--designer-seats)))
    ('repairer 1)
    (_ 1)))

(defun maduin-dispatch--active-role-count (role)
  "Return number of active sessions with ROLE."
  (cl-count-if (lambda (e) (eq (plist-get e :role) role))
               maduin-dispatch--active))

(defun maduin-dispatch--free-seat (role)
  "Return first free seat name for ROLE, or nil.
Free = a configured seat with no active session of ROLE occupying it."
  (let* ((seats (pcase role
                  ('implementer (maduin-dispatch--fleet-seats))
                  ('designer (maduin-dispatch--designer-seats))
                  (_ nil)))
         (occupied (mapcar (lambda (e) (plist-get e :seat))
                           maduin-dispatch--active)))
    (cl-find-if (lambda (s) (not (member s occupied))) seats)))

;;; Workdir + plan injection

(defun maduin-dispatch--ensure-workdir (seat)
  "Ensure worktree for SEAT; return its path."
  (or (maduin-workspace-ensure seat)
      (maduin-workspace-path seat)))

(defun maduin-dispatch--spec (task)
  "Return task spec plist for TASK via show-fn, or nil."
  (condition-case nil
      (funcall maduin-dispatch--show-fn task)
    (error nil)))

(defun maduin-dispatch--implement-plan (task)
  "Build implement plan string for TASK."
  (let ((spec (maduin-dispatch--spec task)))
    (format
     "Implement bd task %s.\n\nTitle: %s\n\nDescription:\n%s\n\n\
Write output.md describing what you changed. Commit your work to this \
branch when done. If blocked, explain why — do not invent work."
     task
     (or (plist-get spec :title) "?")
     (or (plist-get spec :desc) "?"))))

(defun maduin-dispatch--design-plan (task)
  "Build design plan string for TASK."
  (let ((spec (maduin-dispatch--spec task)))
    (format
     "Design bd task %s.\n\nTitle: %s\n\nDescription:\n%s\n\n\
Produce a design document and record design + acceptance criteria for \
the task. If blocked, explain why — do not invent work."
     task
     (or (plist-get spec :title) "?")
     (or (plist-get spec :desc) "?"))))

(defun maduin-dispatch--repair-plan (seat task)
  "Build conflict-repair plan string for SEAT on TASK."
  (format
   "You are the merge-conflict repairer for seat %s (task %s). A land \
into main failed with conflicts. Task: 1) git merge main 2) resolve ALL \
conflicts 3) git add -A 4) git commit. Report blockers instead of guessing."
   seat task))

(defun maduin-dispatch--plan-for (role task seat)
  "Build plan string for ROLE on TASK at SEAT."
  (pcase role
    ('implementer (maduin-dispatch--implement-plan task))
    ('designer (maduin-dispatch--design-plan task))
    ('repairer (maduin-dispatch--repair-plan seat task))
    (_ (maduin-dispatch--implement-plan task))))

;;; Spawn

(defun maduin-dispatch--spawn (task role seat &optional model plan)
  "Claim TASK and spawn one ROLE session at SEAT.  Return handle or nil.
No-op (nil) when ROLE is at its concurrency cap or no SEAT is free.
PLAN overrides the role's default plan string (designer owns its prompt)."
  (unless (>= (maduin-dispatch--active-role-count role)
              (maduin-dispatch--role-cap role))
    (let ((seat (or seat (maduin-dispatch--free-seat role))))
      (when (and seat (funcall maduin-dispatch--claim-fn task))
        (maduin-dispatch--spawn-session task role seat model plan nil)))))

(defun maduin-dispatch--spawn-session (task role seat model plan fallback-attempted)
  "Spawn one ROLE session for TASK at SEAT (task already claimed) and
register it in `maduin-dispatch--active'.  MODEL and PLAN override the
seat defaults when non-nil.  FALLBACK-ATTEMPTED flags a re-dispatch
using the seat's fallback model.  Return handle, or nil on spawn failure."
  (let* ((model (or model (maduin-dispatch--seat-model-for role seat)))
         (agent (maduin-dispatch--seat-agent-for role))
         (workdir (funcall maduin-dispatch--workdir-fn seat))
         (plan (or plan (maduin-dispatch--plan-for role task seat)))
         (sid (funcall maduin-dispatch--session-run-fn workdir model agent plan)))
    (when sid
      (push (list :handle sid :seat seat :role role :task task
                  :model model :fallback-attempted fallback-attempted)
            maduin-dispatch--active)
      (when (boundp 'maduin-cockpit-refresh-hook)
        (run-hook-with-args 'maduin-cockpit-refresh-hook))
      sid)))

;;; Completion → land → close

(defun maduin-dispatch--format-diffs (diffs)
  "Format DIFFS (list of diff alists) into a close-output string."
  (if (null diffs)
      "no diffs reported"
    (mapconcat (lambda (d)
                 (format "%s:\n%s"
                         (or (cdr (assq 'file d)) "?")
                         (or (cdr (assq 'patch d)) "")))
               diffs "\n\n")))

(defun maduin-dispatch--complete (entry sid)
  "Handle successful completion of session for ENTRY (plist) with SID.
Land the branch, then close the task only on a successful land.  On
conflict dispatch a repairer (unless already repairing); on other land
failure leave the task open.  Designer (decomposition) sessions never
close: the epic stays open until its children are implemented."
  (let* ((seat (plist-get entry :seat))
         (task (plist-get entry :task))
         (role (plist-get entry :role))
         (diffs (funcall maduin-dispatch--diff-fn sid))
         (output (maduin-dispatch--format-diffs diffs))
         (land (condition-case nil
                   (funcall maduin-dispatch--land-fn seat)
                 (error nil))))
    (cond
     ((eq land t)
      (unless (eq role 'designer)
        (if (funcall maduin-dispatch--landed-fn seat)
            (funcall maduin-dispatch--close-fn
                     task output (funcall maduin-dispatch--workdir-fn seat))
          (funcall maduin-dispatch--comment-fn task
                   "land reported success but branch not in main — left open")
          (funcall maduin-dispatch--release-fn task))))
     ((eq land 'conflict)
      (funcall maduin-dispatch--comment-fn task "merge conflict — repairer dispatched")
      (unless (eq role 'repairer)
        (maduin-dispatch-repair seat task)))
     (t
      (funcall maduin-dispatch--comment-fn task "land failed — task left open")
      ;; Release the claim so the task returns to open (bd ready) instead of
      ;; staying in_progress forever.
      (funcall maduin-dispatch--release-fn task)))))

(defun maduin-dispatch--fail (entry sid)
  "Handle failed session for ENTRY: report and release the claim so the
task returns to open (bd ready) rather than staying claimed in_progress.
A usage/rate-limit failure on an implementer session that has a
fallback model (and has not already used it) is instead re-dispatched
with the fallback model, keeping the claim in place."
  (let ((role (plist-get entry :role))
        (seat (plist-get entry :seat))
        (task (plist-get entry :task)))
    (if (and (not (plist-get entry :fallback-attempted))
             (maduin-session-usage-limited-p sid)
             (maduin-dispatch--seat-fallback role))
        (progn
          (funcall maduin-dispatch--comment-fn
                   task "usage limit — retrying with fallback model")
          (maduin-dispatch--spawn-session
           task 'implementer seat
           (maduin-dispatch--seat-fallback role) nil t))
      (funcall maduin-dispatch--comment-fn task "session failed — task left open")
      (funcall maduin-dispatch--release-fn task))))

(defun maduin-dispatch--on-complete (sid status)
  "Completion hook: route a finished session SID (STATUS `completed'|`failed').
Only acts on sessions this dispatcher spawned; foreign sessions are
ignored.  Always deletes the session (ephemeral — sessions live only
while work is in flight)."
  (let ((entry (cl-find-if (lambda (e) (string= (plist-get e :handle) sid))
                           maduin-dispatch--active)))
    (when entry
      (setq maduin-dispatch--active
            (delq entry maduin-dispatch--active))
      (unwind-protect
          (if (eq status 'completed)
              (maduin-dispatch--complete entry sid)
            (maduin-dispatch--fail entry sid))
        (funcall maduin-dispatch--session-delete-fn sid))
      (maduin-dispatch--maybe-drained)
      (when (boundp 'maduin-cockpit-refresh-hook)
        (run-hook-with-args 'maduin-cockpit-refresh-hook)))))

(defun maduin-dispatch--maybe-drained ()
  "Signal soft-stop completion when draining and no sessions remain."
  (when (and maduin-dispatch--draining (null maduin-dispatch--active))
    (setq maduin-dispatch--draining nil)
    (message "maduin stopped (drained)")))

;;; Public API

(defun maduin-dispatch-implement (task)
  "Claim TASK and dispatch to a free implementer seat.
Return a session handle, or nil when all seats are busy or spawn fails."
  (maduin-dispatch--spawn task 'implementer nil))

(defun maduin-dispatch-design (task &optional plan)
  "Dispatch a design session for TASK on a free designer seat (Ramuh).
Return a session handle, or nil when busy or spawn fails.  PLAN, when
given, overrides the default design plan (the designer owns the prompt)."
  (maduin-dispatch--spawn task 'designer nil nil plan))

(defun maduin-dispatch-repair (seat task)
  "Dispatch a conflict-repair session (Phoenix) for SEAT on TASK.
Return a session handle, or nil when a repairer is already active."
  (maduin-dispatch--spawn task 'repairer seat))

;;; Recovery — orphaned in_progress tasks

(defun maduin-dispatch--orphaned-tasks ()
  "Return in_progress task IDs with no active dispatch session.
A task claimed (in_progress) but absent from `maduin-dispatch--active'
was orphaned by an Emacs quit mid-task; `bd ready' never re-surfaces it."
  (let ((active (mapcar (lambda (e) (plist-get e :task))
                        maduin-dispatch--active)))
    (cl-remove-if (lambda (task) (member task active))
                  (or (funcall maduin-dispatch--in-progress-fn) nil))))

(defun maduin-dispatch--recover ()
  "Re-dispatch orphaned in_progress tasks.
Each orphan is re-dispatched via `maduin-dispatch-implement'; re-claim
is idempotent (`bd update --claim' on an already-claimed-by-us task) so
the spawn proceeds without double-work.  Respects the concurrency cap:
a full fleet no-ops and retries on a later tick.  Return the number of
tasks re-dispatched."
  (let ((n 0))
    (dolist (task (maduin-dispatch--orphaned-tasks))
      (when (maduin-dispatch-implement task)
        (setq n (1+ n))))
    n))

;;; Run loop

(defun maduin-dispatch--undecomposed-epics ()
  "Return open epic IDs lacking decomposition (no child issues)."
  (let ((epics (or (funcall maduin-dispatch--open-epics-fn) nil)))
    (cl-remove-if (lambda (epic)
                    (funcall maduin-dispatch--epic-children-fn epic))
                  epics)))

(defun maduin-dispatch--decompose-epics ()
  "Dispatch a Ramuh decomposition session per undecomposed open epic.
Respects the designer concurrency cap (1 seat): `maduin-dispatch--spawn'
no-ops once the designer role is at its cap."
  (dolist (epic (maduin-dispatch--undecomposed-epics))
    (funcall maduin-dispatch--epic-decompose-fn epic)))

(defun maduin-dispatch-run-loop ()
  "One tick: recover orphaned in_progress tasks, poll ready bd tasks and
dispatch implement for each, then dispatch Ramuh decomposition for open
epics lacking decomposition.  Stops spawning once the implementer
concurrency cap is reached.  No-op while draining (soft stop in progress)."
  (unless maduin-dispatch--draining
    (maduin-dispatch--recover)
    (let ((ready (funcall maduin-dispatch--ready-fn)))
      (dolist (task ready)
        (maduin-dispatch-implement task)))
    (maduin-dispatch--decompose-epics)))

;;; Lifecycle

(defun maduin-dispatch--register-hook ()
  "Register the completion hook once."
  (unless (memq #'maduin-dispatch--on-complete maduin-session-on-complete-hook)
    (add-hook 'maduin-session-on-complete-hook #'maduin-dispatch--on-complete)))

(defun maduin-dispatch--handoff-live ()
  "Delete all in-flight sessions and clear the registry.
Tasks are left open; their worktree changes persist for the next run."
  (dolist (entry (copy-sequence maduin-dispatch--active))
    (funcall maduin-dispatch--session-delete-fn (plist-get entry :handle)))
  (setq maduin-dispatch--active nil))

(defun maduin-dispatch-start ()
  "Activate dispatchers: register the completion hook and start the
run-loop timer.  Runs one recovery pass immediately so tasks orphaned
by a prior mid-task quit are re-dispatched without waiting for the
first timer tick."
  (maduin-dispatch--register-hook)
  (when maduin-dispatch--timer
    (cancel-timer maduin-dispatch--timer)
    (setq maduin-dispatch--timer nil))
  (let ((interval (or (maduin-dispatch--config-get 'fleet 'poll-interval) 30)))
    (setq maduin-dispatch--timer
          (run-at-time interval interval #'maduin-dispatch-run-loop)))
  (maduin-dispatch--recover)
  t)

(defun maduin-dispatch-stop (&optional hard)
  "Deactivate dispatchers.  Cancel the run-loop timer.
Without HARD (default): soft stop — stop picking up new work and let
in-flight sessions drain; `maduin-dispatch--on-complete' signals
\"drained\" when the last session finishes.  With HARD non-nil:
immediately delete any live sessions (tasks stay open)."
  (when maduin-dispatch--timer
    (cancel-timer maduin-dispatch--timer)
    (setq maduin-dispatch--timer nil))
  (if hard
      (maduin-dispatch--handoff-live)
    (if maduin-dispatch--active
        (progn
          (setq maduin-dispatch--draining t)
          (message "maduin: draining %d session(s)..."
                   (length maduin-dispatch--active)))
      (setq maduin-dispatch--draining nil)
      (message "maduin stopped"))))

(maduin-dispatch--register-hook)

(provide 'maduin-dispatch)

;;; maduin-dispatch.el ends here
