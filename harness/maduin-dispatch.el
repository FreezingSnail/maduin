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
(require 'maduin-backend)
(require 'maduin-bd-bridge)
(require 'maduin-bd-async)
(require 'maduin-workspace)
(require 'maduin-pipeline)

;;; Injection seams (function-valued defvars; tests let-bind these).

(defun maduin-dispatch--backend-run (workdir model agent plan backend &optional effort)
  "Run BACKEND in WORKDIR with MODEL, AGENT, PLAN, and optional EFFORT."
  (maduin-backend-run backend workdir model agent plan effort))

(defun maduin-dispatch--backend-diff (backend sid)
  "Return BACKEND's diff for opaque session SID."
  (maduin-backend-diff backend sid))

(defun maduin-dispatch--backend-delete (backend sid)
  "Delete opaque session SID through its stored BACKEND."
  (maduin-backend-delete backend sid))

(defvar maduin-dispatch--session-run-fn #'maduin-dispatch--backend-run
  "Function `(workdir model agent plan backend &optional effort)' →
session handle or nil.")

(defvar maduin-dispatch--session-delete-fn #'maduin-dispatch--backend-delete
  "Function `(backend sid)' → boolean.")

(defvar maduin-dispatch--diff-fn #'maduin-dispatch--backend-diff
  "Function `(backend sid)' → list of diff alists | nil.")

(defvar maduin-dispatch--land-fn #'maduin-pipeline-land-branch
  "Function `(seat &optional stamp)' → t | `conflict' | nil.
Mocks must accept the optional provenance STAMP argument.")

(defvar maduin-dispatch--landed-fn #'maduin-pipeline-landed-p
  "Function `(seat)' → non-nil when the seat's branch tip is an ancestor
of main.")

(defvar maduin-dispatch--close-fn #'maduin-bd-close
  "Function `(task output)' → boolean.
OUTPUT becomes the bd close reason; no file is written into any worktree.")

(defvar maduin-dispatch--claim-fn #'maduin-bd-claim
  "Function `(task)' → boolean.")

(defvar maduin-dispatch--release-fn #'maduin-bd-release
  "Function `(task)' → boolean.  Releases a failed task's claim (status → open).")

(defvar maduin-dispatch--ready-fn #'maduin-bd-ready-tasks
  "Function `()' → list of ready task id strings | nil.")

(defvar maduin-dispatch--show-fn #'maduin-bd-show
  "Function `(task)' → plist (:title :desc :status :deps) | nil.")

(defvar maduin-dispatch--difficulty-fn #'maduin-bd-difficulty
  "Function `(task)' → `low', `high', or nil.")

(defvar maduin-dispatch--comment-fn #'maduin-bd-comment
  "Function `(id text)' → boolean.")

(defvar maduin-dispatch--workdir-fn #'maduin-dispatch--ensure-workdir
  "Function `(seat)' → worktree directory string.")

(defvar maduin-dispatch--sync-fn #'maduin-workspace-sync
  "Function `(seat)' → `synced', `dirty', `conflict', or nil.
Run before a seat is claimed so work starts from the current main.")

(defvar maduin-dispatch--open-epics-fn #'maduin-bd-open-epics
  "Function `()' → list of open epic id strings | nil.")

(defvar maduin-dispatch--in-progress-fn #'maduin-bd-in-progress-tasks
  "Function `()' → list of in_progress task id strings | nil.
Recovery seam: detects tasks orphaned by an Emacs quit mid-task.")

(defvar maduin-dispatch--epic-children-fn #'maduin-bd-epic-children
  "Function `(epic)' → list of child id strings | nil.")

;; Async polling seams deliberately sit alongside the synchronous seams above.
;; The latter remain the contract for direct recovery/decomposition helpers and
;; their existing tests; run-loop polling must never invoke them.
(defvar maduin-dispatch--ready-async-fn #'maduin-bd-async-ready-tasks
  "Function `(callback)' → async handle; CALLBACK receives IDS and success.")

(defvar maduin-dispatch--in-progress-async-fn #'maduin-bd-async-in-progress-tasks
  "Function `(callback)' → async handle; CALLBACK receives IDS and success.")

(defvar maduin-dispatch--open-epics-async-fn #'maduin-bd-async-open-epics
  "Function `(callback)' → async handle; CALLBACK receives IDS and success.")

(defvar maduin-dispatch--epic-children-async-fn #'maduin-bd-async-epic-children
  "Function `(epic callback)' → async handle; CALLBACK receives IDS and success.")

(defvar maduin-dispatch--epic-decompose-fn #'maduin-designer-decompose-epic
  "Function `(epic)' → session handle | nil.
Reuses maduin-designer machinery (Ramuh decomposition session).")

(declare-function maduin-designer-decompose-epic "maduin-designer.el")

;;; Active-session registry (concurrency tracking).

(defvar maduin-dispatch--active nil
  "List of plists for in-flight sessions.

Entry shape (additive — older entries missing new keys are tolerated):

  (:handle SID :seat SEAT :role ROLE :task TASK
   :model MODEL :backend BACKEND :difficulty SYMBOL|nil :effort STRING|nil
   :fallback-attempted BOOL
   :started FLOAT      ; `float-time' at push
   :status SYMBOL      ; working | running | repairing | failed
   :phase  STRING|nil) ; last session phase

ROLE is a symbol: `implementer', `designer' or `repairer'.
A fallback re-spawn creates a NEW entry with a fresh :started (uptime
measures the current attempt, not the original claim).")

(defvar maduin-dispatch--timer nil
  "Run-loop timer, or nil when dispatchers are inactive.")

(defvar maduin-dispatch--draining nil
  "Non-nil while a soft stop is draining in-flight sessions.
The run-loop picks up no new work while draining.")

(defvar maduin-dispatch--tick-in-flight nil
  "Non-nil while an asynchronous dispatch polling chain is outstanding.")

(defvar maduin-dispatch--tick-notify-pending nil
  "Non-nil when a polling tick deferred a cockpit refresh notification.")

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

(defun maduin-dispatch--seat-model-for (role seat &optional backend difficulty)
  "Return ROLE/SEAT's model for BACKEND and optional DIFFICULTY tier.
An explicit BACKEND keeps retry entries sticky; ordinary launches resolve
through `maduin-config-seat-backend', including the crew-wide override."
  (maduin-config-difficulty-model
   role seat (or backend (maduin-config-seat-backend role seat)) difficulty))

(defun maduin-dispatch--seat-effort-for (role seat backend difficulty)
  "Return ROLE/SEAT's optional BACKEND thinking effort for DIFFICULTY."
  (maduin-config-difficulty-effort role seat backend difficulty))

(defun maduin-dispatch--seat-agent-for (role)
  "Return agent string for ROLE, or nil."
  (pcase role
    ('implementer (maduin-dispatch--config-get 'fleet 'agent))
    ('designer (maduin-dispatch--config-get 'designer 'agent))
    ('repairer (maduin-dispatch--config-get 'repairer 'agent))
    (_ nil)))

(defun maduin-dispatch--seat-fallback (role &optional backend)
  "Return configured fallback model for ROLE on BACKEND, or nil.
BACKEND defaults to `opencode' for compatibility.  The caller supplies the
session entry's sticky backend so mutable seat configuration cannot redirect a
retry.  Kiro fallbacks stay in Kiro's bare-model namespace; OpenCode fallbacks
remain available only where that backend has an explicit configured fallback."
  (let ((section (pcase role
                   ('implementer 'fleet)
                   ('designer 'designer)
                   ('concierge 'concierge)
                   ('reviewer 'reviewer)
                   ('repairer 'repairer)
                   (_ nil))))
    (and section
         (pcase (or backend 'opencode)
           ('opencode (maduin-dispatch--config-get section 'fallback))
           ('kiro (maduin-dispatch--config-get section 'kiro-fallback))))))

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
Commit your work to this branch when done, and describe what you changed \
in the commit message body: that message is the record of the task. Write \
no summary or report files. If blocked, explain why — do not invent work."
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
   "You are the merge-conflict repairer for seat %s (task %s). A land into \
main failed with conflicts. Land reconciles by rebasing, so resolve the same \
way: 1) git rebase main 2) resolve ALL conflicts 3) git add -A 4) git rebase \
--continue, repeating 2-4 until the rebase finishes. Do not merge main into \
this branch: land would replay these commits and re-raise the conflict. \
Describe the resolution in the commit message. Report blockers instead of \
guessing."
   seat task))

(defun maduin-dispatch--plan-for (role task seat)
  "Build plan string for ROLE on TASK at SEAT."
  (pcase role
    ('implementer (maduin-dispatch--implement-plan task))
    ('designer (maduin-dispatch--design-plan task))
    ('repairer (maduin-dispatch--repair-plan seat task))
    (_ (maduin-dispatch--implement-plan task))))

;;; Live-state notifications

(defun maduin-dispatch--notify (&optional _reason)
  "Request a cockpit refresh, coalescing notifications from an active tick."
  (if maduin-dispatch--tick-in-flight
      (setq maduin-dispatch--tick-notify-pending t)
    (when (boundp 'maduin-cockpit-refresh-hook)
      (condition-case nil
          (run-hook-with-args 'maduin-cockpit-refresh-hook)
        (error nil)))))

(defun maduin-dispatch--set-status (handle status)
  "Store changed STATUS on active entry HANDLE and request a refresh.
Return non-nil when HANDLE was active.  Missing entries are a silent no-op."
  (condition-case nil
      (let ((found nil)
            (changed nil))
        (setq maduin-dispatch--active
              (mapcar
               (lambda (entry)
                 ;; Every non-matching entry must be returned unchanged: a
                 ;; missing else branch here silently replaced other seats'
                 ;; entries with nil, breaking completion and drain.
                 (if (and (not found)
                          (equal handle (plist-get entry :handle)))
                     (progn
                       (setq found t)
                       (unless (equal status (plist-get entry :status))
                         (setq changed t)
                         (plist-put entry :status status))
                       entry)
                   entry))
               maduin-dispatch--active))
        (when changed (maduin-dispatch--notify))
        found)
    (error nil)))

(defun maduin-dispatch--on-event (sid phase)
  "Store changed PHASE on active entry SID and nudge the cockpit.
This hook runs from a process filter, so it only mutates state and schedules
work indirectly through `maduin-dispatch--notify'."
  (condition-case nil
      (let ((found nil)
            (phase-changed nil)
            (status nil))
        (setq maduin-dispatch--active
              (mapcar
               (lambda (entry)
                 (if (and (not found)
                          (equal sid (plist-get entry :handle)))
                     (progn
                       (setq found t
                             status (plist-get entry :status))
                       (unless (equal phase (plist-get entry :phase))
                         (setq phase-changed t)
                         (setq entry (plist-put entry :phase phase)))
                       entry)
                   entry))
               maduin-dispatch--active))
        (when (and found (or phase-changed (not (eq status 'running))))
          (if (eq status 'running)
              (maduin-dispatch--notify)
            (maduin-dispatch--set-status sid 'running)))
        nil)
    (error nil)))

;;; Spawn

(defun maduin-dispatch--seat-ready-p (role seat task)
  "Return non-nil when SEAT's worktree is fit to receive TASK for ROLE.

Ensures the worktree exists, then syncs its branch to main so the session
starts from the current baseline instead of whatever main looked like when the
seat last ran.  A repairer is deliberately exempt: it is dispatched *because*
its seat diverges, and syncing would discard the work it must resolve.

A seat whose unlanded work conflicts with main is refused (nil) and TASK is
left ready for another seat; every other outcome proceeds."
  (funcall maduin-dispatch--workdir-fn seat)
  (if (eq role 'repairer)
      t
    (let ((result (condition-case nil
                      (funcall maduin-dispatch--sync-fn seat)
                    (error nil))))
      (if (eq result 'conflict)
          (progn
            (funcall maduin-dispatch--comment-fn
                     task
                     (format "seat %s holds unlanded work conflicting with main — not dispatched"
                             seat))
            nil)
        t))))

(defun maduin-dispatch--spawn (task role seat &optional model plan)
  "Claim TASK and spawn one ROLE session at SEAT.  Return handle or nil.
No-op (nil) when ROLE is at its concurrency cap, no SEAT is free, or SEAT
cannot be synced to main.
PLAN overrides the role's default plan string (designer owns its prompt)."
  (unless (>= (maduin-dispatch--active-role-count role)
              (maduin-dispatch--role-cap role))
    (let ((seat (or seat (maduin-dispatch--free-seat role))))
      (when (and seat (maduin-dispatch--seat-ready-p role seat task))
        (if (funcall maduin-dispatch--claim-fn task)
            (maduin-dispatch--spawn-session task role seat model plan nil)
          (maduin-dispatch--notify)
          nil)))))

(defun maduin-dispatch--spawn-session (task role seat model plan fallback-attempted
                                            &optional backend difficulty effort)
  "Spawn one claimed TASK for ROLE at SEAT and register its BACKEND.
MODEL and PLAN override configured values.  BACKEND is resolved once for a
new launch, then retained for fallback and completion lifecycle calls.
Implementers with no explicit MODEL resolve DIFFICULTY, model, and effort
at spawn; retries pass the stored tier and effort explicitly."
  (let ((backend (or backend (maduin-backend-resolve role seat))))
    (condition-case nil
        (let* ((resolve-tier (and (null model) (eq role 'implementer)))
               (difficulty (if resolve-tier
                               (condition-case nil
                                   (funcall maduin-dispatch--difficulty-fn task)
                                 (error nil))
                             difficulty))
               (model (or model
                          (maduin-dispatch--seat-model-for
                           role seat backend difficulty)))
               (effort (if resolve-tier
                           (maduin-dispatch--seat-effort-for
                            role seat backend difficulty)
                         effort))
               (agent (maduin-dispatch--seat-agent-for role))
               (workdir (funcall maduin-dispatch--workdir-fn seat))
               (plan (or plan (maduin-dispatch--plan-for role task seat)))
               (sid (and backend
                         (funcall maduin-dispatch--session-run-fn
                                  workdir model agent plan backend effort))))
          (if sid
              (progn
                (push (list :handle sid :seat seat :role role :task task
                            :model model :backend backend :difficulty difficulty
                            :effort effort :fallback-attempted fallback-attempted
                            :started (float-time) :status 'working :phase nil)
                      maduin-dispatch--active)
                (maduin-dispatch--notify)
                sid)
            (funcall maduin-dispatch--comment-fn
                     task "session failed — task left open")
            (funcall maduin-dispatch--release-fn task)
            (maduin-dispatch--notify)
            nil))
      (error
       (funcall maduin-dispatch--comment-fn task "session failed — task left open")
       (funcall maduin-dispatch--release-fn task)
       (maduin-dispatch--notify)
       nil))))

;;; Completion → land → close

(defun maduin-dispatch--stamp-for (entry)
  "Return provenance stamp plist for completed dispatch ENTRY.
The attempt's stored model, backend, difficulty, effort, seat, and task are
preserved.  Missing metadata and git lookup failures become nil; this helper
never signals."
  (condition-case nil
      (let* ((role (plist-get entry :role))
             (name (maduin-dispatch--config-get 'harness 'name))
             (version (maduin-dispatch--config-get 'harness 'version))
             (rev-result
              (condition-case nil
                  (funcall maduin-pipeline--git-output-fn
                           (funcall maduin-pipeline--main-root-fn)
                           "rev-parse" "--short" "HEAD")
                (error nil)))
             (rev (and (consp rev-result)
                       (zerop (car rev-result))
                       (stringp (cdr rev-result))
                       (let ((value (string-trim (cdr rev-result))))
                         (unless (string-empty-p value) value)))))
        (list :model (plist-get entry :model)
              :backend (plist-get entry :backend)
              :difficulty (plist-get entry :difficulty)
              :effort (plist-get entry :effort)
              :agent (maduin-dispatch--seat-agent-for role)
              :seat (plist-get entry :seat)
              :task (plist-get entry :task)
              :harness (and name version (format "%s %s" name version))
              :rev rev))
    (error nil)))

(defun maduin-dispatch--format-diffs (diffs)
  "Format adapter DIFFS into a close-output string.
OpenCode returns diff alists; Kiro returns a worktree diff string."
  (cond
   ((null diffs) "no diffs reported")
   ((stringp diffs) diffs)
   (t
    (mapconcat (lambda (d)
                 (format "%s:\n%s"
                         (or (cdr (assq 'file d)) "?")
                         (or (cdr (assq 'patch d)) "")))
               diffs "\n\n"))))

(defun maduin-dispatch--complete (entry sid)
  "Handle successful completion of session for ENTRY (plist) with SID.
Land the branch, then close the task only on a successful land.  On
conflict dispatch a repairer (unless already repairing); on other land
failure leave the task open.  Designer (decomposition) sessions never
close: the epic stays open until its children are implemented."
  (let* ((seat (plist-get entry :seat))
         (task (plist-get entry :task))
         (role (plist-get entry :role))
         (backend (plist-get entry :backend))
         (stamp (maduin-dispatch--stamp-for entry))
         (diffs (funcall maduin-dispatch--diff-fn backend sid))
         (output (maduin-dispatch--format-diffs diffs))
         (land (condition-case nil
                   (funcall maduin-dispatch--land-fn seat stamp)
                 (error nil))))
    (cond
     ((eq land t)
      (unless (eq role 'designer)
        (if (funcall maduin-dispatch--landed-fn seat)
            (funcall maduin-dispatch--close-fn
                     task
                     (concat output
                             (unless (string-suffix-p "\n" output) "\n")
                             "provenance: "
                             (maduin-stamp-format (maduin-stamp-trailers stamp))))
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

(defun maduin-dispatch--fail (entry sid status)
  "Handle failed STATUS for ENTRY, retrying one limited session on fallback.
The retry uses ENTRY's sticky backend, keeps its existing claim, and is bounded
by `:fallback-attempted'.  Every other failure releases the claim."
  (maduin-dispatch--set-status sid 'failed)
  (let* ((role (plist-get entry :role))
         (seat (plist-get entry :seat))
         (task (plist-get entry :task))
         (backend (plist-get entry :backend))
         (fallback (maduin-dispatch--seat-fallback role backend))
         (limited (or (eq status 'limited)
                      (and (eq backend 'opencode)
                           (maduin-session-usage-limited-p sid)))))
    (if (and (not (plist-get entry :fallback-attempted)) limited fallback)
        (progn
          (funcall maduin-dispatch--comment-fn
                   task "usage limit — retrying with fallback model")
          (maduin-dispatch--spawn-session
           task role seat fallback nil t backend
           (plist-get entry :difficulty) (plist-get entry :effort))
          (maduin-dispatch--notify))
      (funcall maduin-dispatch--comment-fn task "session failed — task left open")
      (funcall maduin-dispatch--release-fn task)
      (maduin-dispatch--notify))))

(defun maduin-dispatch--on-complete (sid status)
  "Completion hook: route a finished session SID (STATUS `completed'|`failed').
Only acts on sessions this dispatcher spawned; foreign sessions are
ignored.  Always deletes the session (ephemeral — sessions live only
while work is in flight)."
  (let ((entry (cl-find-if (lambda (e) (equal (plist-get e :handle) sid))
                           maduin-dispatch--active)))
    (when entry
      (unless (eq status 'completed)
        (maduin-dispatch--set-status sid 'failed))
      (setq maduin-dispatch--active
            (delq entry maduin-dispatch--active))
      (maduin-dispatch--notify)
      (unwind-protect
          (if (eq status 'completed)
              (maduin-dispatch--complete entry sid)
            (maduin-dispatch--fail entry sid status))
        (funcall maduin-dispatch--session-delete-fn
                 (plist-get entry :backend) sid))
      (maduin-dispatch--maybe-drained)
      (maduin-dispatch--notify))))

(defun maduin-dispatch--maybe-drained ()
  "Signal soft-stop completion when draining and no sessions remain."
  (when (and maduin-dispatch--draining (null maduin-dispatch--active))
    (setq maduin-dispatch--draining nil)
    (message "maduin stopped (drained)")
    (maduin-dispatch--notify)))

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
  (let ((sid (maduin-dispatch--spawn task 'repairer seat)))
    (when sid (maduin-dispatch--set-status sid 'repairing))
    sid))

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
    (when (> n 0) (maduin-dispatch--notify))
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

(defun maduin-dispatch--recover-tasks (tasks)
  "Re-dispatch orphaned TASKS from one async in-progress snapshot.
Return the count dispatched.  Unlike `maduin-dispatch--recover', this
never starts another bd query."
  (let ((n 0)
        (active (mapcar (lambda (entry) (plist-get entry :task))
                        maduin-dispatch--active)))
    (dolist (task tasks)
      (when (and (not (member task active))
                 (maduin-dispatch-implement task))
        (setq n (1+ n))))
    n))

(defun maduin-dispatch--run-loop-error (stage finish)
  "Log failed async polling STAGE and invoke tick FINISH continuation."
  (maduin-bd--log-error (format "dispatch async %s query failed" stage))
  (funcall finish))

(defun maduin-dispatch-run-loop ()
  "Asynchronously poll, recover, dispatch, and decompose for one tick.
Read-only bd queries yield to Emacs between subprocesses.  Claim, plan
construction (`bd show'), and session spawning remain synchronous: those are
ordered dispatch actions, and a plan must exist before `make-process'."
  (unless (or maduin-dispatch--draining maduin-dispatch--tick-in-flight)
    (setq maduin-dispatch--tick-in-flight t)
    (let ((notified nil)
          (finish (lambda ()
                    (let ((flush maduin-dispatch--tick-notify-pending))
                      (setq maduin-dispatch--tick-in-flight nil
                            maduin-dispatch--tick-notify-pending nil)
                      (when flush (maduin-dispatch--notify))))))
      (cl-labels
          ((notify-once ()
             (unless notified
               (setq notified t)
               (maduin-dispatch--notify)))
           (fail (stage)
             (maduin-dispatch--run-loop-error stage finish))
           (decompose (epics)
             ;; Start every parent query before processing any result: the
             ;; latch joins concurrent child snapshots without serial bd I/O.
             (if (null epics)
                 (funcall finish)
               (let ((remaining (length epics))
                     (failed nil)
                     (undecomposed nil))
                 (dolist (epic epics)
                   (unless
                       (funcall
                        maduin-dispatch--epic-children-async-fn epic
                        (lambda (children ok)
                          (condition-case err
                              (progn
                                (unless ok (setq failed t))
                                (when (and ok (null children))
                                  (push epic undecomposed))
                                (setq remaining (1- remaining))
                                (when (= remaining 0)
                                  (unwind-protect
                                      (cond
                                       (failed
                                        (maduin-bd--log-error
                                         "dispatch async epic children query failed"))
                                       ((not maduin-dispatch--draining)
                                        (dolist (id (nreverse undecomposed))
                                          (funcall maduin-dispatch--epic-decompose-fn id))
                                        (when undecomposed (notify-once))))
                                    (funcall finish))))
                            (error
                             (maduin-bd--log-error
                              (format "dispatch async epic children callback failed: %s"
                                      (error-message-string err)))
                             (funcall finish)))))
                     (setq failed t
                           remaining (1- remaining))))
                 ;; A process which could not start invokes no callback.
                 (when (= remaining 0) (funcall finish)))))
           (open-epics ()
             (unless (funcall maduin-dispatch--open-epics-async-fn
                              (lambda (epics ok)
                                (condition-case err
                                    (if ok
                                        (if maduin-dispatch--draining
                                            (funcall finish)
                                          (decompose epics))
                                      (fail "open epics"))
                                  (error
                                   (maduin-bd--log-error
                                    (format "dispatch async open epics callback failed: %s"
                                            (error-message-string err)))
                                   (funcall finish)))))
               (fail "open epics")))
           (ready ()
             (unless (funcall maduin-dispatch--ready-async-fn
                              (lambda (tasks ok)
                                (condition-case err
                                    (if ok
                                        (progn
                                          (unless maduin-dispatch--draining
                                            (dolist (task tasks)
                                              (maduin-dispatch-implement task)))
                                          (open-epics))
                                      (fail "ready"))
                                  (error
                                   (maduin-bd--log-error
                                    (format "dispatch async ready callback failed: %s"
                                            (error-message-string err)))
                                   (funcall finish)))))
               (fail "ready"))))
        (unless (funcall maduin-dispatch--in-progress-async-fn
                         (lambda (tasks ok)
                           (condition-case err
                               (if ok
                                   (progn
                                     (unless maduin-dispatch--draining
                                       (when (> (maduin-dispatch--recover-tasks tasks) 0)
                                         (notify-once)))
                                     (ready))
                                 (fail "in-progress"))
                             (error
                              (maduin-bd--log-error
                               (format "dispatch async in-progress callback failed: %s"
                                       (error-message-string err)))
                              (funcall finish)))))
          (fail "in-progress"))))))

;;; Lifecycle

(defun maduin-dispatch--register-hook ()
  "Register the completion hook once."
  (unless (memq #'maduin-dispatch--on-complete maduin-session-on-complete-hook)
    (add-hook 'maduin-session-on-complete-hook #'maduin-dispatch--on-complete)))

(defun maduin-dispatch--register-event-hook ()
  "Register the phase-event hook once when the session substrate provides it."
  (condition-case nil
      (when (boundp 'maduin-session-on-event-hook)
        (unless (memq #'maduin-dispatch--on-event
                      (symbol-value 'maduin-session-on-event-hook))
          (add-hook 'maduin-session-on-event-hook #'maduin-dispatch--on-event)))
    (error nil)))

(defun maduin-dispatch--handoff-live ()
  "Delete all in-flight sessions and clear the registry.
Tasks are left open; their worktree changes persist for the next run."
  (dolist (entry (copy-sequence maduin-dispatch--active))
    (funcall maduin-dispatch--session-delete-fn
             (plist-get entry :backend) (plist-get entry :handle)))
  (setq maduin-dispatch--active nil)
  (maduin-dispatch--notify))

(defun maduin-dispatch-start ()
  "Activate dispatchers: register the completion hook and start the
run-loop timer.  Runs one recovery pass immediately so tasks orphaned
by a prior mid-task quit are re-dispatched without waiting for the
first timer tick."
  (maduin-dispatch--register-hook)
  (maduin-dispatch--register-event-hook)
  (when maduin-dispatch--timer
    (cancel-timer maduin-dispatch--timer)
    (setq maduin-dispatch--timer nil))
  (let ((interval (or (maduin-dispatch--config-get 'fleet 'poll-interval) 30)))
    (setq maduin-dispatch--timer
          (run-at-time interval interval #'maduin-dispatch-run-loop)))
  (maduin-dispatch-run-loop)
  (maduin-dispatch--notify)
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
  (when maduin-dispatch--tick-in-flight
    (maduin-bd-async-cancel-all)
    (setq maduin-dispatch--tick-in-flight nil
          maduin-dispatch--tick-notify-pending nil))
  (if hard
      (maduin-dispatch--handoff-live)
    (if maduin-dispatch--active
        (progn
          (setq maduin-dispatch--draining t)
          (message "maduin: draining %d session(s)..."
                   (length maduin-dispatch--active)))
      (setq maduin-dispatch--draining nil)
      (message "maduin stopped")))
  (maduin-dispatch--notify))

(maduin-dispatch--register-hook)
(maduin-dispatch--register-event-hook)

(provide 'maduin-dispatch)

;;; maduin-dispatch.el ends here
