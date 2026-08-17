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
(require 'maduin-bd-bridge)
(require 'maduin-dispatch)
(require 'maduin-cockpit-face)

;; maduin-handoff.el may not exist yet; guard the require.
(condition-case nil
    (require 'maduin-handoff)
  (error nil))

(defvar maduin-cockpit-buffer-name "*maduin-cockpit*"
  "Name of the cockpit dashboard buffer.")

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

(defvar maduin-cockpit--title-cache nil
  "Alist ((TASK-ID . TITLE) ...) caching bd task titles.
Cleared at the start of every `maduin-cockpit-refresh'.")

(defun maduin-cockpit--task-title (task-id)
  "Return title string for TASK-ID via `bd show', or nil on failure.
Results are cached in `maduin-cockpit--title-cache'; failures are not.
Tolerates either an object or an array shape in the JSON output."
  (when task-id
    (or (cdr (assoc task-id maduin-cockpit--title-cache))
        (let* ((res (maduin-bd--run
                     (format "bd show %s --json" task-id)))
               (data (maduin-bd--json-data (cdr res)))
               (title (and (= 0 (car res))
                           (or (and (listp data)
                                    (cl-loop for item in data
                                             for ttl = (and (listp item)
                                                            (alist-get 'title item))
                                             when (stringp ttl) return ttl))
                               ;; bd show may emit a bare object; the
                               ;; bridge drops non-array shapes, so parse
                               ;; the raw output here.
                               (let ((obj (condition-case nil
                                              (json-read-from-string (cdr res))
                                            (error nil))))
                                 (and (listp obj)
                                      (alist-get 'title obj)))))))
          (when title
            (push (cons task-id title) maduin-cockpit--title-cache))
          title))))

(defun maduin-cockpit--status-pill (status)
  "Return STATUS as a pill string with a face text property.
Known STATUS symbols carry their `maduin-cockpit-state-face'; unknown or
nil statuses render as plain text (\"dead\" when nil)."
  (let* ((face (maduin-cockpit-state-face status))
         (text (cond ((null status) "dead")
                     ((stringp status) status)
                     (t (symbol-name status)))))
    (if face
        (propertize text 'face face)
      text)))

(defun maduin-cockpit--seat-status (seat)
  "Return rich plist for SEAT:
\(:seat :role :status :task-id :task-title :model :uptime :phase).
A dispatch entry wins for :role/:status/:task-id; absent fields fall
back to `maduin-agent-status'.  :phase stays nil until sessions expose
it.  Never signals."
  (let* ((entry (cl-find-if (lambda (e) (equal (plist-get e :seat) seat))
                            maduin-dispatch--active))
         (agent (maduin-agent-status seat)))
    (list :seat seat
          :role (or (and entry (plist-get entry :role))
                    (and agent (plist-get agent :role)))
          :status (or (and entry (plist-get entry :status))
                      (and entry 'working)
                      (and agent (plist-get agent :status)))
          :task-id (or (and entry (plist-get entry :task))
                       (and agent (plist-get agent :task)))
          :task-title (maduin-cockpit--task-title
                       (or (and entry (plist-get entry :task))
                           (and agent (plist-get agent :task))))
          :model (or (and entry (plist-get entry :model))
                     (and agent (plist-get agent :model)))
          :uptime (or (and entry (plist-get entry :uptime))
                      (and agent (plist-get agent :uptime)))
          :phase nil)))

(defun maduin-cockpit--task-string (status)
  "Return \"TASK-ID — TITLE\" from rich STATUS plist, or \"—\"."
  (let ((id (plist-get status :task-id))
        (title (plist-get status :task-title)))
    (cond ((null id) "—")
          (title (format "%s — %s" id title))
          (t (format "%s —" id)))))

(defun maduin-cockpit--uptime-string (status)
  "Return integer uptime seconds from STATUS plist, or \"—\"."
  (let ((uptime (and status (plist-get status :uptime))))
    (if uptime (number-to-string (round uptime)) "—")))

(defun maduin-cockpit--rows ()
  "Return tabulated-list rows for all configured seats."
  (cl-loop for (seat . role) in (maduin-cockpit--seats)
           for st = (maduin-cockpit--seat-status seat)
           collect (list seat
                         (vector seat
                                 (or (plist-get st :role) role)
                                 (maduin-cockpit--status-pill
                                  (plist-get st :status))
                                 (maduin-cockpit--task-string st)
                                 (or (plist-get st :model) "—")
                                 (maduin-cockpit--uptime-string st)
                                 (or (plist-get st :phase) "—")))))

(defun maduin-cockpit--pipeline-summary ()
  "Return pipeline stat chips (icon + label + count), space-separated.
Each chip carries its `maduin-cockpit-chip-face' text property."
  (let* ((ps (maduin-pipeline-status))
         (specs '((queued . "◐")
                  (active . "◉")
                  (completed . "✓")
                  (blocked . "✗")
                  (fleet-free . "○")
                  (fleet-busy . "●"))))
    (mapconcat
     (lambda (spec)
       (let* ((k (car spec))
              (n (or (plist-get ps (intern (format ":%s" k))) 0))
              (chip (format "%s %s %d" (cdr spec) k n))
              (face (maduin-cockpit-chip-face k)))
         (if face (propertize chip 'face face) chip)))
     specs " ")))

;;;###autoload
(defun maduin-cockpit-show ()
  "Create (or switch to) the cockpit dashboard buffer.
Return the buffer."
  (interactive)
  (let ((buf (get-buffer-create maduin-cockpit-buffer-name)))
    (switch-to-buffer buf)
    (tabulated-list-mode)
    (use-local-map maduin-cockpit-map)
    (maduin-cockpit-refresh)
    buf))

(defun maduin-cockpit-refresh ()
  "Rebuild cockpit rows, title cache, and pipeline chip summary."
  (interactive)
  (setq maduin-cockpit--title-cache nil)
  (setq tabulated-list-format
        (vector '("Seat" 13 t)
                '("Role" 9 t)
                '("Status" 12 t)
                '("Task" 30 nil)
                '("Model" 16 t)
                '("Uptime(s)" 10 t)
                '("Activity" 12 t)))
  (setq tabulated-list-entries (maduin-cockpit--rows))
  (tabulated-list-print t)
  (goto-char (point-max))
  (let ((inhibit-read-only t))
    (insert (maduin-cockpit--pipeline-summary)))
  (goto-char (point-min)))

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
