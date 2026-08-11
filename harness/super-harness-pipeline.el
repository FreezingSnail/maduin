;;; super-harness-pipeline.el --- crew/fleet pipeline  -*- lexical-binding: t; -*-

;;; Commentary:

;; Producer/consumer core.  Crew agents produce bd tasks; fleet
;; agents consume them.  Fleet polling runs on `run-at-time' timers,
;; dispatching ready bd tasks to fleet seats.  Crew dispatch sends
;; prompts to free crew agents.

;;; Code:

(defconst super-harness-pipeline--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing super-harness-pipeline.el.")

(add-to-list 'load-path super-harness-pipeline--dir)

(require 'cl-lib)
(require 'super-harness-bd-bridge)
(require 'super-harness-agent)
(require 'super-harness-session)
(require 'super-harness-config)

(defvar super-harness-pipeline-timers nil
  "Alist ((SEAT-NAME . TIMER) ...) of active fleet polling timers.")

;;; Config access

(defun super-harness-pipeline--config ()
  "Return the super-harness config alist.
Load harness/config.el explicitly because super-harness-config.el
is a stub and the real values live there."
  (or (bound-and-true-p super-harness-config)
      (condition-case nil
          (progn
            (load-file (expand-file-name "config.el" super-harness-pipeline--dir))
            (bound-and-true-p super-harness-config))
        (error nil))))

(defun super-harness-pipeline--config-section (section)
  "Return alist for SECTION of super-harness config, or nil."
  (cdr (assq section (super-harness-pipeline--config))))

(defun super-harness-pipeline--config-get (section key)
  "Return value of KEY in SECTION of super-harness config, or nil."
  (cdr (assq key (super-harness-pipeline--config-section section))))

;;; Seats

(defun super-harness-pipeline-fleet-seats ()
  "Return list of fleet seat names from config."
  (delq nil
        (mapcar (lambda (s)
                  (when (listp s) (alist-get 'name s)))
                (super-harness-pipeline--config-get 'fleet 'seats))))

(defun super-harness-pipeline--crew-seats ()
  "Return list of crew seat names from config."
  (delq nil
        (mapcar (lambda (s)
                  (when (listp s) (alist-get 'name s)))
                (super-harness-pipeline--config-get 'crew 'seats))))

(defun super-harness-pipeline--seat-model (seat-name)
  "Return model configured for fleet SEAT-NAME, or \"default\"."
  (let ((seats (super-harness-pipeline--config-get 'fleet 'seats)))
    (or (and (listp seats)
             (let ((entry (cl-find-if
                           (lambda (s) (string= (alist-get 'name s) seat-name))
                           seats)))
               (and entry (alist-get 'model entry))))
        "default")))

(defun super-harness-pipeline-find-free-agent (role)
  "Return first free seat name for ROLE (crew or fleet), or nil.
Free means session alive and status not `working'."
  (let ((seats (if (string= role "fleet")
                   (super-harness-pipeline-fleet-seats)
                 (super-harness-pipeline--crew-seats))))
    (cl-find-if
     (lambda (seat)
       (and (super-harness-session-alive-p seat)
            (let ((st (super-harness-agent-status seat)))
              (not (eq (plist-get st :status) 'working)))))
     seats)))

;;; Fleet polling

(defun super-harness-pipeline-start-fleet (seat-name)
  "Start fleet polling timer for SEAT-NAME.  Return the timer.
Repeats every `fleet.poll-interval' from config (default 30s)."
  (let* ((interval (or (super-harness-pipeline--config-get 'fleet 'poll-interval) 30))
         (old (cdr (assoc seat-name super-harness-pipeline-timers)))
         (timer (run-at-time interval interval
                             #'super-harness-pipeline--poll seat-name)))
    (when old (cancel-timer old))
    (setq super-harness-pipeline-timers
          (cons (cons seat-name timer)
                (assq-delete-all seat-name super-harness-pipeline-timers)))
    timer))

(defun super-harness-pipeline-stop-fleet (seat-name)
  "Cancel fleet polling timer for SEAT-NAME."
  (let ((entry (assoc seat-name super-harness-pipeline-timers)))
    (when entry
      (cancel-timer (cdr entry))
      (setq super-harness-pipeline-timers
            (assq-delete-all seat-name super-harness-pipeline-timers)))))

(defun super-harness-pipeline--last-output ()
  "Return last 8192 chars of current buffer, stripped of text props."
  (buffer-substring-no-properties
   (max (point-min) (- (point-max) 8192))
   (point-max)))

(defun super-harness-pipeline--poll (seat-name)
  "Poll for a ready bd task and dispatch to fleet SEAT-NAME.
Skip when SEAT-NAME is already working.  On agent exit, close the
task with the agent's output and mark the seat idle."
  (let ((status (super-harness-agent-status seat-name)))
    (unless (and status (eq (plist-get status :status) 'working))
      (let ((task (car (super-harness-bd-ready-tasks))))
        (when task
          (super-harness-bd-claim task)
          (let* ((model (super-harness-pipeline--seat-model seat-name))
                 (workdir (expand-file-name
                           (or (super-harness-pipeline--config-get 'workspaces 'path)
                               "harness/workspaces")))
                 (proc (super-harness-agent-spawn
                        seat-name "fleet" model workdir))))
            (if proc
                (let ((buf (process-buffer proc)))
                  (when buf
                    (with-current-buffer buf
                      (setq-local super-harness-current-task task)
                      (setq-local super-harness-status 'working)))
                  (set-process-sentinel
                   proc
                   (lambda (p _event)
                     (when (eq (process-status p) 'exit)
                       (let ((pbuf (process-buffer p)))
                         (super-harness-bd-close
                          task
                          (when (buffer-live-p pbuf)
                            (with-current-buffer pbuf
                              (super-harness-pipeline--last-output))))
                         (when (buffer-live-p pbuf)
                           (with-current-buffer pbuf
                             (setq-local super-harness-current-task nil)
                             (setq-local super-harness-status 'idle)))))))
              (message "super-harness: spawn %s failed for task %s"
                       seat-name task))))))))

;;; Crew dispatch

(defun super-harness-pipeline-dispatch-crew (prompt)
  "Send PROMPT to first free crew agent.
Warn when no crew agent is free."
  (let ((seat (super-harness-pipeline-find-free-agent "crew")))
    (if seat
        (let* ((buf (super-harness-session--buffer seat))
               (proc (and buf (get-buffer-process buf))))
          (if (and proc (process-live-p proc))
              (process-send-string proc prompt)
            (when buf
              (with-current-buffer buf
                (let ((inhibit-read-only t))
                  (goto-char (point-max))
                  (insert prompt))))))
      (message "super-harness: no free crew agent; prompt undelivered"))))

;;; Review (placeholder for v0.2)

(defun super-harness-pipeline-review (task-id)
  "Placeholder review of TASK-ID: message and remember.
Full review gate lands in v0.2."
  (message "super-harness: reviewing %s" task-id)
  (super-harness-bd-remember (format "reviewed %s" task-id)))

;;; Status

(defun super-harness-pipeline--count (status)
  "Return bd issue count with STATUS via `bd count', or 0."
  (let* ((res (super-harness-bd--run
               (format "bd count --status %s --json" status)))
         (data (and (= 0 (car res))
                    (super-harness-bd--json-data (cdr res)))))
    (or (and data (alist-get 'count (car data))) 0)))

(defun super-harness-pipeline-status ()
  "Return plist (:queued :active :completed :blocked :fleet-free :fleet-busy)."
  (let* ((fleet (super-harness-pipeline-fleet-seats))
         (busy (cl-count-if
                (lambda (s)
                  (eq (plist-get (super-harness-agent-status s) :status) 'working))
                fleet)))
    (list :queued (length (or (super-harness-bd-ready-tasks) nil))
          :active (super-harness-pipeline--count "in-progress")
          :completed (super-harness-pipeline--count "closed")
          :blocked (super-harness-pipeline--count "blocked")
          :fleet-free (- (length fleet) busy)
          :fleet-busy busy)))

(provide 'super-harness-pipeline)

;;; super-harness-pipeline.el ends here
