;;; maduin-gate.el --- approval gate: stage/approve/reject via defer-undefer. -*- lexical-binding: t; -*-

;; Approval gate built on bd defer/undefer + a "staged" label.
;;
;;   stage       = set design/acceptance + defer + label "staged"
;;   approve     = undefer + remove "staged" label  (task re-enters bd ready)
;;   reject      = comment feedback; task stays staged
;;   staged-list = bd query "status=deferred AND label=staged"
;;
;; `bd undefer' does NOT cascade to children, so `maduin-gate-approve-epic'
;; loops each staged child individually.

(require 'cl-lib)
(require 'maduin-bd-bridge)

(defconst maduin-gate-staged-label "staged"
  "Label marking a task as awaiting approval (deferred + this label).")

(defun maduin-gate-stage (task design acceptance)
  "Stage TASK for review: set DESIGN/ACCEPTANCE, defer it, label it staged.
Return t if all steps succeed, nil otherwise."
  (and (maduin-bd-update-design-acceptance task design acceptance)
       (maduin-bd-defer task)
       (maduin-bd-label task maduin-gate-staged-label)))

(defun maduin-gate-approve (id)
  "Approve ID: undefer it and remove the staged label. Return t on success.
Undefer does not cascade to children — call `maduin-gate-approve-epic' to
approve a whole epic."
  (interactive
   (list (completing-read "Approve task: " (maduin-gate-staged-list))))
  (and (maduin-bd-undefer id)
       (maduin-bd-label-remove id maduin-gate-staged-label)))

(defun maduin-gate-reject (id feedback)
  "Reject ID: comment FEEDBACK, leave it staged. Return t on success."
  (interactive
   (list (completing-read "Reject task: " (maduin-gate-staged-list))
         (read-string "Feedback: ")))
  (maduin-bd-comment id feedback))

(defun maduin-gate-staged-list ()
  "Return list of staged task IDs (deferred + staged label).
Interactively, message the list."
  (interactive)
  (let ((staged (maduin-bd-query
                 (format "status=deferred AND label=%s" maduin-gate-staged-label))))
    (when (called-interactively-p 'any)
      (if staged
          (message "staged tasks: %s" (mapconcat #'identity staged ", "))
        (message "no staged tasks")))
    staged))

(defun maduin-gate-approve-epic (epic-id)
  "Approve EPIC-ID: undefer every staged child (undefer does not cascade).
Return list of child IDs approved, or nil if none matched."
  (let ((staged (maduin-bd-query
                 (format "parent=%s AND status=deferred AND label=%s"
                         epic-id maduin-gate-staged-label)))
        approved)
    (dolist (id staged)
      (when (maduin-gate-approve id)
        (push id approved)))
    (nreverse approved)))

(provide 'maduin-gate)

;;; maduin-gate.el ends here
