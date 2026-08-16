;;; maduin-cockpit.el --- dashboard buffer rendering  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Wheelhouse rolodex: a tabulated-list buffer showing every agent
;; seat (concierge + designer + implementer) with status, task, and
;; uptime, plus a pipeline health summary.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)

;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))

(require 'maduin-session)
(require 'maduin-agent)
(require 'maduin-pipeline)
(require 'maduin-config)
(require 'maduin-dispatch nil t) ; guarded: dispatch may not exist standalone

;; maduin-handoff.el may not exist yet; guard the require.
(condition-case nil
    (require 'maduin-handoff)
  (error nil))

(defvar maduin-cockpit-buffer-name "*maduin-cockpit*"
  "Name of the cockpit dashboard buffer.")

(defvar maduin-cockpit-refresh-interval 5
  "Seconds between automatic cockpit refreshes while the buffer is visible.")

(defvar maduin-cockpit--timer nil
  "Timer driving periodic cockpit refresh, or nil when not running.")

(defvar maduin-cockpit-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'maduin-cockpit-attach)
    (define-key map (kbd "r") #'maduin-cockpit-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "k") #'maduin-cockpit-kill)
    map)
  "Keymap for the cockpit buffer.")

(defun maduin-cockpit--seats ()
  "Return alist ((SEAT-NAME . ROLE) ...) from config seats."
  (append
   (mapcar (lambda (s) (cons s "concierge"))
           (maduin-pipeline--concierge-seats))
   (mapcar (lambda (s) (cons s "designer"))
           (maduin-pipeline--designer-seats))
   (mapcar (lambda (s) (cons s "implementer"))
           (maduin-pipeline-fleet-seats))))

(defun maduin-cockpit--status-string (status)
  "Return string for STATUS symbol, defaulting to \"dead\"."
  (or (and status (symbol-name status)) "dead"))

(defun maduin-cockpit--task-string (status)
  "Return task id from STATUS plist, or \"—\" when none."
  (or (and status (plist-get status :task)) "—"))

(defun maduin-cockpit--uptime-string (status)
  "Return integer uptime seconds from STATUS plist, or \"—\"."
  (let ((uptime (and status (plist-get status :uptime))))
    (if uptime (number-to-string (round uptime)) "—")))

(defun maduin-cockpit--dispatch-entry (seat)
  "Return the dispatch active entry for SEAT, or nil.
An active entry is a plist (:handle :seat :role :task) from
`maduin-dispatch--active'.  Demand-driven dispatch has no persistent
seat buffers, so this registry is the source of truth for in-flight work."
  (when (boundp 'maduin-dispatch--active)
    (cl-find-if (lambda (e) (string= (plist-get e :seat) seat))
                maduin-dispatch--active)))

(defun maduin-cockpit--seat-status (seat)
  "Return a status plist for SEAT, preferring dispatch-active state.
Falls back to `maduin-agent-status' (legacy seat-buffer model) when no
dispatch entry is in flight."
  (let ((entry (maduin-cockpit--dispatch-entry seat)))
    (if entry
        (list :status 'working
              :task (plist-get entry :task)
              :uptime nil)
      (maduin-agent-status seat))))

(defun maduin-cockpit--rows ()
  "Return tabulated-list rows for all configured seats."
  (cl-loop for (seat . role) in (maduin-cockpit--seats)
           for status = (maduin-cockpit--seat-status seat)
           collect (list seat
                         (vector seat role
                                 (maduin-cockpit--status-string
                                  (and status (plist-get status :status)))
                                 (maduin-cockpit--task-string status)
                                 (maduin-cockpit--uptime-string status)))))

(defun maduin-cockpit--pipeline-summary ()
  "Return string summarizing pipeline status."
  (let* ((ps (maduin-pipeline-status))
         (fmt "queued %d | active %d | completed %d | blocked %d | fleet-free %d | fleet-busy %d"))
    (format fmt
            (plist-get ps :queued)
            (plist-get ps :active)
            (plist-get ps :completed)
            (plist-get ps :blocked)
            (plist-get ps :fleet-free)
            (plist-get ps :fleet-busy))))

;;;###autoload
(defun maduin-cockpit-show ()
  "Create (or switch to) the cockpit dashboard buffer.
Return the buffer."
  (interactive)
  (let ((buf (get-buffer-create maduin-cockpit-buffer-name)))
    (switch-to-buffer buf)
    (tabulated-list-mode)
    (use-local-map maduin-cockpit-map)
    (with-current-buffer buf
      (add-hook 'kill-buffer-hook #'maduin-cockpit--stop-timer nil t))
    (maduin-cockpit-refresh)
    (maduin-cockpit--start-timer)
    buf))

(defun maduin-cockpit-refresh ()
  "Rebuild cockpit rows and pipeline summary."
  (interactive)
  (setq tabulated-list-format
        (vector '("Agent" 12 t)
                '("Role" 8 t)
                '("Status" 10 t)
                '("Task" 18 nil)
                '("Uptime(s)" 10 t)))
  (setq tabulated-list-entries (maduin-cockpit--rows))
  (tabulated-list-print t)
  (goto-char (point-max))
  (let ((inhibit-read-only t))
    (insert (maduin-cockpit--pipeline-summary)))
  (goto-char (point-min)))

(defun maduin-cockpit--start-timer ()
  "Ensure the cockpit auto-refresh timer is running."
  (unless (and maduin-cockpit--timer
               (timerp maduin-cockpit--timer))
    (setq maduin-cockpit--timer
          (run-at-time maduin-cockpit-refresh-interval
                       maduin-cockpit-refresh-interval
                       #'maduin-cockpit--auto-refresh))))

(defun maduin-cockpit--stop-timer ()
  "Cancel the cockpit auto-refresh timer."
  (when maduin-cockpit--timer
    (cancel-timer maduin-cockpit--timer)
    (setq maduin-cockpit--timer nil)))

(defun maduin-cockpit--auto-refresh ()
  "Refresh the cockpit while its buffer is visible.
Self-cancelling: when the buffer is gone or no longer shown in any
window, stop the timer.  Refresh is skipped while the buffer is buried
(hidden but alive) so work in other buffers is not interrupted."
  (let ((buf (get-buffer maduin-cockpit-buffer-name)))
    (if (or (null buf) (null (get-buffer-window buf 'visible)))
        (maduin-cockpit--stop-timer)
      (with-current-buffer buf
        (maduin-cockpit-refresh)))))

(defun maduin-cockpit-attach ()
  "Switch to the agent buffer named by the row under point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless id
      (error "maduin-cockpit: no agent on this line"))
    (maduin-session-switch id)))

(defun maduin-cockpit-kill ()
  "Kill (with handoff when available) the agent under point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless id
      (error "maduin-cockpit: no agent on this line"))
    (if (fboundp 'maduin-handoff-restart)
        (maduin-handoff-restart id)
      (maduin-agent-kill id))))

(provide 'maduin-cockpit)

;;; maduin-cockpit.el ends here
