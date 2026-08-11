;;; super-harness-cockpit.el --- dashboard buffer rendering  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Wheelhouse rolodex: a tabulated-list buffer showing every agent
;; seat (crew + fleet) with status, task, and uptime, plus a pipeline
;; health summary.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)

;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))

(require 'super-harness-session)
(require 'super-harness-agent)
(require 'super-harness-pipeline)
(require 'super-harness-config)

;; super-harness-handoff.el may not exist yet; guard the require.
(condition-case nil
    (require 'super-harness-handoff)
  (error nil))

(defvar super-harness-cockpit-buffer-name "*super-harness-cockpit*"
  "Name of the cockpit dashboard buffer.")

(defvar super-harness-cockpit-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'super-harness-cockpit-attach)
    (define-key map (kbd "r") #'super-harness-cockpit-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "k") #'super-harness-cockpit-kill)
    map)
  "Keymap for the cockpit buffer.")

(defun super-harness-cockpit--seats ()
  "Return alist ((SEAT-NAME . ROLE) ...) from config (crew then fleet)."
  (append
   (mapcar (lambda (s) (cons s "crew"))
           (super-harness-pipeline--crew-seats))
   (mapcar (lambda (s) (cons s "fleet"))
           (super-harness-pipeline-fleet-seats))))

(defun super-harness-cockpit--status-string (status)
  "Return string for STATUS symbol, defaulting to \"dead\"."
  (or (and status (symbol-name status)) "dead"))

(defun super-harness-cockpit--task-string (status)
  "Return task id from STATUS plist, or \"—\" when none."
  (or (and status (plist-get status :task)) "—"))

(defun super-harness-cockpit--uptime-string (status)
  "Return integer uptime seconds from STATUS plist, or \"—\"."
  (let ((uptime (and status (plist-get status :uptime))))
    (if uptime (number-to-string (round uptime)) "—")))

(defun super-harness-cockpit--rows ()
  "Return tabulated-list rows for all configured seats."
  (cl-loop for (seat . role) in (super-harness-cockpit--seats)
           for status = (super-harness-agent-status seat)
           collect (list seat
                         (vector seat role
                                 (super-harness-cockpit--status-string
                                  (and status (plist-get status :status)))
                                 (super-harness-cockpit--task-string status)
                                 (super-harness-cockpit--uptime-string status)))))

(defun super-harness-cockpit--pipeline-summary ()
  "Return string summarizing pipeline status."
  (let* ((ps (super-harness-pipeline-status))
         (fmt "queued %d | active %d | completed %d | blocked %d | fleet-free %d | fleet-busy %d"))
    (format fmt
            (plist-get ps :queued)
            (plist-get ps :active)
            (plist-get ps :completed)
            (plist-get ps :blocked)
            (plist-get ps :fleet-free)
            (plist-get ps :fleet-busy))))

;;;###autoload
(defun super-harness-cockpit-show ()
  "Create (or switch to) the cockpit dashboard buffer.
Return the buffer."
  (interactive)
  (let ((buf (get-buffer-create super-harness-cockpit-buffer-name)))
    (switch-to-buffer buf)
    (tabulated-list-mode)
    (use-local-map super-harness-cockpit-map)
    (super-harness-cockpit-refresh)
    buf))

(defun super-harness-cockpit-refresh ()
  "Rebuild cockpit rows and pipeline summary."
  (interactive)
  (setq tabulated-list-format
        (vector '("Agent" 12 t)
                '("Role" 8 t)
                '("Status" 10 t)
                '("Task" 18 nil)
                '("Uptime(s)" 10 t)))
  (setq tabulated-list-entries (super-harness-cockpit--rows))
  (tabulated-list-print t)
  (goto-char (point-max))
  (let ((inhibit-read-only t))
    (insert (super-harness-cockpit--pipeline-summary)))
  (goto-char (point-min)))

(defun super-harness-cockpit-attach ()
  "Switch to the agent buffer named by the row under point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless id
      (error "super-harness-cockpit: no agent on this line"))
    (super-harness-session-switch id)))

(defun super-harness-cockpit-kill ()
  "Kill (with handoff when available) the agent under point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless id
      (error "super-harness-cockpit: no agent on this line"))
    (if (fboundp 'super-harness-handoff-restart)
        (super-harness-handoff-restart id)
      (super-harness-agent-kill id))))

(provide 'super-harness-cockpit)

;;; super-harness-cockpit.el ends here
