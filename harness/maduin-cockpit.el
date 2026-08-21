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
(require 'maduin-pipeline)
(require 'maduin-state)
(require 'maduin-config)
(require 'maduin-bd-bridge)
(require 'maduin-bd-async)
(require 'maduin-dispatch)
(require 'maduin-cockpit-face)
(require 'maduin-cockpit-bar)
(require 'maduin-cockpit-config)

;; chaplet (optional) — embedded inbox.  Symbols are fboundp-guarded at
;; runtime and declared here so this file byte-compiles without chaplet.
(declare-function chaplet-list-set-view "chaplet-list" (name))
(declare-function chaplet-list-refresh "chaplet-list" ())
;; evil (optional) — evil-aware bindings.  Declared so this file
;; byte-compiles when evil is not installed (AGENTS.md: use the
;; evil-define-key* function, not the macro).
(declare-function evil-define-key* "evil-core" (state keymap &rest bindings))
(declare-function maduin-concierge "maduin-concierge" ())
(declare-function maduin-concierge-dismiss "maduin-concierge" ())
(declare-function maduin-designer-drop-in "maduin-designer" (&optional seat))
(declare-function maduin-designer-pending-tasks "maduin-designer" ())
(declare-function maduin-terminal--buffer-name "maduin-terminal" (role seat))

(defvar maduin-cockpit-buffer-name "*maduin-cockpit*"
  "Name of the cockpit dashboard buffer.")

(defvar maduin-cockpit-refresh-interval 5
  "Seconds between automatic cockpit refreshes while the buffer is visible.")

(defvar maduin-cockpit--timer nil
  "Timer driving periodic cockpit refresh, or nil when not running.")

(defvar maduin-cockpit-inbox-refresh-interval nil
  "Seconds between opt-in embedded inbox refreshes, or nil to disable them.")

(defvar maduin-cockpit--inbox-timer nil
  "Timer driving opt-in embedded inbox refreshes, or nil when not running.")

(defvar maduin-cockpit-refresh-hook nil
  "Hook run to request a cockpit refresh.
External modules (dispatch, session) run this hook to nudge a refresh
without requiring maduin-cockpit.  Refresh is scheduled on an idle
timer and only happens while the cockpit buffer is visible.")

(defvar maduin-cockpit-min-render-interval 0.25
  "Minimum seconds between scheduled cockpit renders.")

(defvar maduin-cockpit--pending-render nil
  "Leading or trailing render timer, or nil when no render is armed.")

(defvar maduin-cockpit--last-render nil
  "Float time of the most recent cockpit render, or nil when never rendered.")

(defvar maduin-cockpit--now-fn #'float-time
  "Function of no arguments returning the scheduler's current float time.")

(defvar chaplet-auto-refresh t
  "When non-nil, chaplet auto-refreshes its buffers on focus.
Declared here so maduin-cockpit byte-compiles without chaplet.  The
timer-driven cockpit refresh gates its embedded-inbox refresh on this
flag, so the inbox is not double-refreshed by both the cockpit timer
and chaplet's own focus hook.")

(defvar maduin-cockpit-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    map)
  "Keymap for the cockpit buffer.")

(defconst maduin-cockpit--bindings
  '(("r"   . maduin-cockpit-refresh)
    ("q"   . quit-window)
    ("i"   . maduin-cockpit-inbox)
    ("b"   . maduin-cockpit--toggle-backend)
    ("c"   . maduin-cockpit-config)
    ("a"   . maduin-concierge)
    ("A"   . maduin-concierge-dismiss)
    ("n"   . maduin-designer-drop-in)
    ("p"   . maduin-designer-pending-tasks))
  "Cockpit keybindings as ((KEY . DEF) ...), KEY a `kbd' string.
Single source of truth; mirrored into evil normal/motion states when
evil is available.")

(defconst maduin-cockpit--chip-glyphs
  '((queued "◐" "q") (active "◉" "*") (completed "✓" "+")
    (blocked "✗" "x") (fleet-free "○" "-") (fleet-busy "●" "#"))
  "Pipeline chip glyphs as (KEY UNICODE ASCII).")

(defconst maduin-cockpit--role-order
  '("concierge" "designer" "implementer")
  "Stable default role grouping order for cockpit rows.")

(defconst maduin-cockpit--evil-suppress-keys
  '("v" "V" "C-v" "C" "d" "D" "s" "S" "x" "X" "R")
  "Single-char motions suppressed in evil states only.
In the read-only cockpit these would leak into visual/change state;
they are bound to nil in evil normal/motion states while the plain map
keeps only the shared r/q/i bindings.")

(defun maduin-cockpit--bind (key def)
  "Bind KEY (a `kbd' string) to DEF in the plain cockpit map and, when
evil is available, in evil normal/motion states.
Single source of truth for cockpit keybindings (AGENTS.md)."
  (define-key maduin-cockpit-map (kbd key) def)
  (when (and (featurep 'evil) (fboundp 'evil-define-key*))
    (evil-define-key* 'normal maduin-cockpit-map (kbd key) def)
    (evil-define-key* 'motion maduin-cockpit-map (kbd key) def)))

(defun maduin-cockpit--evil-setup ()
  "Mirror cockpit bindings into evil normal/motion states and suppress
read-only leak motions in those states only.  No-op when evil is absent."
  (when (and (featurep 'evil) (fboundp 'evil-define-key*))
    (dolist (binding maduin-cockpit--bindings)
      (maduin-cockpit--bind (car binding) (cdr binding)))
    (dolist (key maduin-cockpit--evil-suppress-keys)
      (let ((k (kbd key)))
        (evil-define-key* 'normal maduin-cockpit-map k nil)
        (evil-define-key* 'motion maduin-cockpit-map k nil)))))

;; Build the plain-map bindings through the helper (single source of truth).
(dolist (binding maduin-cockpit--bindings)
  (maduin-cockpit--bind (car binding) (cdr binding)))

(defun maduin-cockpit--seats ()
  "Return alist ((SEAT-NAME . ROLE) ...) from config seats."
  (append
   (mapcar (lambda (s) (cons s "concierge"))
           (maduin-pipeline--concierge-seats))
   (mapcar (lambda (s) (cons s "designer"))
           (maduin-pipeline--designer-seats))
   (mapcar (lambda (s) (cons s "implementer"))
           (maduin-pipeline-fleet-seats))))

(defvar maduin-cockpit-title-negative-ttl 60.0
  "Seconds a failed task-title lookup remains cached before one retry.")

(defvar maduin-cockpit--title-queue nil
  "Task ids awaiting deferred title resolution.")

(defvar maduin-cockpit--title-requested (make-hash-table :test #'equal)
  "Set of task ids queued for, or awaiting, title resolution.")

(defvar maduin-cockpit--title-timer nil
  "Single-shot timer that drains `maduin-cockpit--title-queue'.")

(defvar-local maduin-cockpit--header-cache ""
  "Cached header line rendered by `maduin-cockpit--render-header'.")

(defvar-local maduin-cockpit--header-installed nil
  "Non-nil after the cockpit has installed its header line form.")

(defvar-local maduin-cockpit--render-signature nil
  "Hash of the rows and pipeline snapshot last rendered in this buffer.")

(defun maduin-cockpit--titles ()
  "Return the task-id to (TITLE-or-nil . FETCHED-AT) title snapshot."
  (let ((titles (maduin-state-get 'titles)))
    (and (hash-table-p titles) titles)))

(defun maduin-cockpit--title (task-id)
  "Purely read TASK-ID's cached title, returning a string or nil."
  (let* ((titles (maduin-cockpit--titles))
         (entry (and task-id titles (gethash task-id titles))))
    (and (consp entry) (car entry))))

(defun maduin-cockpit--title-negative-fresh-p (task-id &optional now)
  "Return non-nil when TASK-ID has a still-fresh negative title entry."
  (let* ((titles (maduin-cockpit--titles))
         (entry (and task-id titles (gethash task-id titles))))
    (and (consp entry) (null (car entry)) (numberp (cdr entry))
         (<= (- (or now (float-time)) (cdr entry))
             maduin-cockpit-title-negative-ttl))))

(defun maduin-cockpit--title-put (task-id title)
  "Store TASK-ID's TITLE-or-nil result in the titles snapshot."
  (let ((titles (or (maduin-cockpit--titles)
                    (make-hash-table :test #'equal))))
    (puthash task-id (cons title (float-time)) titles)
    (maduin-state-put 'titles titles)))

(defun maduin-cockpit--title-from-output (output)
  "Return the first string title parsed from bd show JSON OUTPUT.
Accept both normal array output and a bare object fallback."
  (let ((data (maduin-bd--json-data output)))
    (or (cl-loop for item in data
                 for title = (and (listp item) (alist-get 'title item))
                 when (stringp title) return title)
        (let ((object (maduin-bd--json-decode output)))
          (and (listp object) (alist-get 'title object))))))

(defun maduin-cockpit--title-finish (task-id exit-code output)
  "Record TASK-ID async result from EXIT-CODE and OUTPUT, then repaint."
  (remhash task-id maduin-cockpit--title-requested)
  (let ((title (and (= exit-code 0)
                    (maduin-cockpit--title-from-output output))))
    (maduin-cockpit--title-put task-id title)
    (unless title
      (when (= exit-code 0)
        (maduin-bd--log-error
         (format "bd show %s returned no title" task-id))))
    (maduin-cockpit--schedule-refresh)))

(defun maduin-cockpit--title-drain ()
  "Start queued task-title requests after the render stack has returned."
  (setq maduin-cockpit--title-timer nil)
  (let ((queue maduin-cockpit--title-queue))
    (setq maduin-cockpit--title-queue nil)
    (dolist (task-id queue)
      (unless (maduin-bd-async-call
               (list "show" task-id "--json")
               (lambda (exit-code output)
                 (maduin-cockpit--title-finish task-id exit-code output)))
        (remhash task-id maduin-cockpit--title-requested)
        (maduin-cockpit--title-put task-id nil)))))

(defun maduin-cockpit--title-request (task-id)
  "Defer an async title request for TASK-ID unless its cache is fresh."
  (when (and task-id
             (not (maduin-cockpit--title task-id))
             (not (maduin-cockpit--title-negative-fresh-p task-id))
             (not (gethash task-id maduin-cockpit--title-requested)))
    (puthash task-id t maduin-cockpit--title-requested)
    (push task-id maduin-cockpit--title-queue)
    (unless (timerp maduin-cockpit--title-timer)
      (setq maduin-cockpit--title-timer
            (run-at-time 0 nil #'maduin-cockpit--title-drain)))))

(defun maduin-cockpit--task-title (task-id)
  "Compatibility alias for the pure cached title read of TASK-ID."
  (maduin-cockpit--title task-id))

(defun maduin-cockpit--status-pill (status)
  "Return STATUS as a pill string with a face text property.
Known STATUS symbols carry their `maduin-cockpit-state-face'; unknown or
nil statuses render as plain text (\"dead\" when nil)."
  (let* ((face (if (eq status 'discussing)
                   'maduin-cockpit-state-running
                 (maduin-cockpit-state-face status)))
         (text (cond ((null status) "dead")
                     ((stringp status) status)
                     (t (symbol-name status)))))
    (if face
        (propertize text 'face face)
      text)))

(defun maduin-cockpit--seat-role (seat)
  "Return configured role symbol for SEAT, or nil when SEAT is unknown."
  (let ((role (cdr (assoc seat (maduin-cockpit--seats)))))
    (and role (intern role))))

(defun maduin-cockpit--concierge-live-p (seat)
  "Return non-nil when concierge SEAT has a live terminal buffer.
Missing terminal support or malformed seat state never interrupts a
cockpit refresh."
  (condition-case nil
      (and (fboundp 'maduin-terminal--buffer-name)
           (buffer-live-p
            (get-buffer (maduin-terminal--buffer-name 'concierge seat))))
    (error nil)))

(defun maduin-cockpit--idle-config (role seat)
  "Return idle ROLE and SEAT's effective backend and model plist, or nil.
Configuration is hand-editable, so malformed or missing values must not
interrupt cockpit rendering.  Resolution deliberately uses the central
configuration APIs, preserving crew-wide backend overrides."
  (condition-case nil
      (when role
        (let ((backend (maduin-config-seat-backend role seat)))
          (list :backend backend
                :model (maduin-config-seat-model role seat backend))))
    (error nil)))

(defun maduin-cockpit--uptime (entry)
  "Return elapsed seconds since ENTRY's :started timestamp, or nil."
  (let ((started (plist-get entry :started)))
    (and started (- (float-time) started))))

(defun maduin-cockpit--seat-status (seat)
  "Return rich plist for SEAT:
\(:seat :role :status :task-id :task-title :model :backend :uptime :phase).
Fields come solely from the dispatch entry (`maduin-dispatch--active');
no entry → idle row.  Active backends are launch-time values; idle
backends reflect current runtime configuration.  Never signals."
  (let* ((entry (cl-find-if (lambda (e) (equal (plist-get e :seat) seat))
                            maduin-dispatch--active))
         (task-id (and entry (plist-get entry :task)))
         (task-title (maduin-cockpit--title task-id))
         (role (maduin-cockpit--seat-role seat))
         (idle-config (and (null entry) (maduin-cockpit--idle-config role seat))))
    (when (and task-id (null task-title))
      (maduin-cockpit--title-request task-id))
    (list :seat seat
          :role (and entry (plist-get entry :role))
          :status (if entry
                      (or (plist-get entry :status) 'working)
                    (and (eq role 'concierge)
                         (maduin-cockpit--concierge-live-p seat)
                         'discussing))
          :task-id task-id
          :task-title task-title
          :model (if entry
                     (plist-get entry :model)
                   (plist-get idle-config :model))
          :backend (if entry
                       (plist-get entry :backend)
                     (plist-get idle-config :backend))
          :uptime (and entry
                       (or (maduin-cockpit--uptime entry)
                           (plist-get entry :uptime)))
          :phase (and entry (plist-get entry :phase)))))

(defun maduin-cockpit--placeholder ()
  "Return a dim em-dash placeholder for an unavailable cockpit value."
  (propertize "—" 'face 'maduin-cockpit-placeholder))

(defun maduin-cockpit--task-string (status)
  "Return a styled, 30-column task cell from rich STATUS, or a placeholder."
  (let ((id (plist-get status :task-id))
        (title (plist-get status :task-title)))
    (if (null id)
        (maduin-cockpit--placeholder)
      (let ((styled-id (propertize id 'face 'maduin-cockpit-task-id)))
        (if title
            (let* ((available (max 0 (- 30 (string-width id) 3)))
                   (short-title (truncate-string-to-width
                                 title available 0 nil "…")))
              (concat styled-id " — "
                      (propertize short-title
                                  'face 'maduin-cockpit-task-title)))
          (concat styled-id " " (maduin-cockpit--placeholder)))))))

(defun maduin-cockpit--uptime-string (status)
  "Return formatted elapsed uptime from STATUS, or a placeholder when absent."
  (let ((uptime (and status (plist-get status :uptime))))
    (if (null uptime)
        (maduin-cockpit--placeholder)
      (let* ((seconds (max 0 (floor uptime)))
             (hours (/ seconds 3600))
             (minutes (% (/ seconds 60) 60))
             (secs (% seconds 60)))
        (if (> hours 0)
            (format "%02d:%02d:%02d" hours minutes secs)
          (format "%02d:%02d" minutes secs))))))

(defun maduin-cockpit--ordered-seats ()
  "Return configured seats in stable, explicit role-group order."
  (let ((seats (maduin-cockpit--seats)))
    (append
     (cl-loop for role in maduin-cockpit--role-order
              append (cl-remove-if-not
                      (lambda (seat) (equal (cdr seat) role)) seats))
     (cl-remove-if (lambda (seat)
                     (member (cdr seat) maduin-cockpit--role-order))
                   seats))))

(defun maduin-cockpit--rows ()
  "Return tabulated-list rows for all configured seats, grouped by role."
  (cl-loop for (seat . role) in (maduin-cockpit--ordered-seats)
           for st = (maduin-cockpit--seat-status seat)
           collect (list seat
                         (vector seat
                                 (let ((display-role (or (plist-get st :role) role)))
                                   (propertize
                                    (if (symbolp display-role)
                                        (symbol-name display-role)
                                      display-role)
                                    'face 'maduin-cockpit-role))
                                 (maduin-cockpit--status-pill
                                  (plist-get st :status))
                                 (maduin-cockpit--task-string st)
                                 (or (plist-get st :model)
                                     (maduin-cockpit--placeholder))
                                 (let ((backend (plist-get st :backend)))
                                   (if backend
                                       (propertize (symbol-name backend)
                                                   'face 'maduin-cockpit-backend)
                                     (maduin-cockpit--placeholder)))
                                 (maduin-cockpit--uptime-string st)
                                 (or (plist-get st :phase)
                                     (maduin-cockpit--placeholder))))))

(defun maduin-cockpit--toggle-backend ()
  "Cycle the selected idle seat's runtime backend and refresh the cockpit."
  (interactive)
  (let* ((seat (tabulated-list-get-id))
         (role (and (stringp seat) (maduin-cockpit--seat-role seat))))
    (unless role
      (user-error "No configured maduin seat at point"))
    (when (cl-find-if (lambda (entry) (equal (plist-get entry :seat) seat))
                      maduin-dispatch--active)
      (user-error "Cannot change backend for active seat %s" seat))
    (maduin-config-set-seat-backend
     role seat
     (pcase (maduin-config-seat-backend role seat)
       ('opencode 'kiro)
       ('kiro 'opencode)
       (_ (user-error "Unsupported backend for seat %s" seat))))
    (maduin-cockpit-refresh)))

(defun maduin-cockpit--glyph (key)
  "Return KEY's displayable Unicode chip glyph, or its ASCII fallback."
  (let ((glyphs (assq key maduin-cockpit--chip-glyphs)))
    (when glyphs
      (if (char-displayable-p (string-to-char (nth 1 glyphs)))
          (nth 1 glyphs)
        (nth 2 glyphs)))))

(defun maduin-cockpit--pipeline-summary (&optional status)
  "Return STATUS pipeline stat chips (icon + label + count), space-separated.
When STATUS is nil, read the current snapshot for compatibility callers."
  (let ((ps (or status (maduin-pipeline-status))))
    (mapconcat
     (lambda (spec)
       (let* ((k (car spec))
              (n (or (plist-get ps (intern (format ":%s" k))) 0))
              (chip (format "%s %s %d" (maduin-cockpit--glyph k) k n))
              (face (maduin-cockpit-chip-face k)))
         (if face (propertize chip 'face face) chip)))
     maduin-cockpit--chip-glyphs " ")))

(defun maduin-cockpit--idle-p (&optional status)
  "Return non-nil when no dispatch work or queued STATUS work exists.
When STATUS is nil, read the current snapshot for compatibility callers."
  (condition-case nil
      (and (null maduin-dispatch--active)
           (equal (plist-get (or status (maduin-pipeline-status)) :queued) 0))
    (error nil)))

(defun maduin-cockpit--cue ()
  "Return the propertized empty-cockpit cue."
  (propertize "no work in flight · [a] summon concierge · [c] config"
              'face 'maduin-cockpit-cue))

(defun maduin-cockpit--run-state ()
  "Return the current dispatch run state as a display string."
  (cond (maduin-dispatch--draining "draining")
        ((timerp maduin-dispatch--timer) "running")
        (t "stopped")))

(defun maduin-cockpit--header-string (&optional status)
  "Return cached-header content for STATUS.
When STATUS is nil, read the current snapshot for compatibility callers."
  (let* ((harness (cdr (assq 'harness maduin-config)))
         (name (or (cdr (assq 'name harness)) "maduin"))
         (version (or (cdr (assq 'version harness))
                      (maduin-cockpit--placeholder))))
    (concat (propertize (format "%s %s · %s · "
                               name version (maduin-cockpit--run-state))
                        'face 'maduin-cockpit-header)
            (maduin-cockpit--pipeline-summary status))))

(defun maduin-cockpit--render-header (status)
  "Install the cheap header evaluator and update its cache from STATUS."
  (unless maduin-cockpit--header-installed
    (setq-local header-line-format '((:eval maduin-cockpit--header-cache)))
    (setq-local maduin-cockpit--header-installed t))
  (let ((header (maduin-cockpit--header-string status)))
    (unless (equal header maduin-cockpit--header-cache)
      (setq-local maduin-cockpit--header-cache header)
      (force-mode-line-update))))

(defun maduin-cockpit--ensure-format ()
  "Establish the constant tabulated-list format without resetting sorting."
  (unless tabulated-list-format
    (setq tabulated-list-format
          (vector '("Seat" 13 t)
                  '("Role" 9 t)
                  '("Status" 12 t)
                  '("Task" 30 nil)
                  '("Model" 16 t)
                  '("Backend" 10 t)
                  '("Uptime" 10 t)
                  '("Activity" 12 t)))
    (setq-local maduin-cockpit--render-signature nil)))

(defun maduin-cockpit--print-rows (rows)
  "Print ROWS while retaining the current row."
  (setq tabulated-list-entries rows)
  (tabulated-list-print t))

(defun maduin-cockpit--render-footer (status)
  "Render the empty-state cue for STATUS after the table without moving point."
  (condition-case nil
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (when (maduin-cockpit--idle-p status)
            (insert "\n" (maduin-cockpit--cue)))))
    (error nil)))

;;;###autoload
(defun maduin-cockpit-show ()
  "Create (or switch to) the cockpit dashboard buffer, and embed the
chaplet inbox in a lower window when chaplet is available.
Return the cockpit buffer."
  (interactive)
  (let ((buf (get-buffer-create maduin-cockpit-buffer-name)))
    (switch-to-buffer buf)
    (tabulated-list-mode)
    (use-local-map maduin-cockpit-map)
    (maduin-cockpit--evil-setup)
    (maduin-cockpit-bar-install)
    (with-current-buffer buf
      (add-hook 'kill-buffer-hook #'maduin-cockpit--stop-timer nil t))
    (maduin-cockpit--register-live-updates)
    (maduin-pipeline-status-refresh #'maduin-cockpit--schedule-refresh)
    (maduin-cockpit-refresh)
    (maduin-cockpit--start-timer)
    (maduin-cockpit--embed-inbox)
    (maduin-cockpit--start-inbox-timer)
    buf))

(defun maduin-cockpit-refresh (&optional refresh-inbox)
  "Render the current cockpit snapshot without synchronous pipeline I/O.
Rows and footer are rebuilt only when their rows-plus-status signature
changes.  Every actual render records its time for the shared scheduler.
When REFRESH-INBOX is non-nil, also refresh the embedded chaplet inbox."
  (interactive (list t))
  (setq maduin-cockpit--last-render (funcall maduin-cockpit--now-fn))
  (let* ((window (get-buffer-window (current-buffer) 'visible))
         (window-start (and (window-live-p window) (window-start window)))
         (status (maduin-pipeline-status))
         (rows (maduin-cockpit--rows))
         (signature (sxhash-equal (list rows status))))
    (maduin-cockpit--ensure-format)
    (unless (equal signature maduin-cockpit--render-signature)
      (maduin-cockpit--print-rows rows)
      (maduin-cockpit--render-footer status)
      (setq-local maduin-cockpit--render-signature signature))
    (maduin-cockpit--render-header status)
    (when (and window-start (window-live-p window))
      (set-window-start window window-start t))
    (when refresh-inbox
      (maduin-cockpit--inbox-refresh))))

(defun maduin-cockpit--start-timer ()
  "Ensure the cockpit auto-refresh timer is running."
  (unless (and maduin-cockpit--timer
               (timerp maduin-cockpit--timer))
    (setq maduin-cockpit--timer
          (run-at-time maduin-cockpit-refresh-interval
                       maduin-cockpit-refresh-interval
                       #'maduin-cockpit--auto-refresh))))

(defun maduin-cockpit--stop-timer ()
  "Cancel all cockpit timers, including a pending scheduled render."
  (when maduin-cockpit--timer
    (cancel-timer maduin-cockpit--timer)
    (setq maduin-cockpit--timer nil))
  (when maduin-cockpit--inbox-timer
    (cancel-timer maduin-cockpit--inbox-timer)
    (setq maduin-cockpit--inbox-timer nil))
  (when maduin-cockpit--pending-render
    (cancel-timer maduin-cockpit--pending-render)
    (setq maduin-cockpit--pending-render nil)))

(defun maduin-cockpit--auto-refresh ()
  "Request a cockpit refresh while its buffer is visible.
Self-cancel when the buffer is gone or hidden.  The five-second timer remains
the freshness driver, but all renders pass through the shared scheduler."
  (let ((buf (get-buffer maduin-cockpit-buffer-name)))
    (if (or (null buf) (null (get-buffer-window buf 'visible)))
        (maduin-cockpit--stop-timer)
      (with-current-buffer buf
        (maduin-pipeline-status-refresh #'maduin-cockpit--schedule-refresh)
        (maduin-cockpit--schedule-refresh)))))

;;; Embedded chaplet inbox

(defconst maduin-cockpit--inbox-buffer-name "*chaplet*"
  "Buffer name of the embedded chaplet inbox list buffer.
Reuses chaplet's single list buffer (`chaplet-list--buffer-name').")

(defun maduin-cockpit--embed-inbox ()
  "Embed the chaplet inbox in a lower window below the cockpit.
Return the inbox window, or nil when chaplet is unavailable or the split
fails.  The cockpit buffer stays in the selected (main) window; the inbox
buffer lands in the new lower window, so killing the cockpit leaves the
inbox usable."
  (if (not (and (require 'chaplet nil t)
                (fboundp 'chaplet-list-set-view)))
      (progn
        (message "maduin-cockpit: chaplet not installed; inbox omitted")
        nil)
    (condition-case nil
        (let ((win (split-window-below)))
          (with-selected-window win
            (chaplet-list-set-view 'inbox))
          win)
      (error nil))))

(defun maduin-cockpit--inbox-refresh ()
  "Refresh the embedded chaplet inbox list buffer, when present.
Silent no-op when chaplet is absent or the inbox buffer is gone."
  (when (fboundp 'chaplet-list-refresh)
    (let ((buf (get-buffer maduin-cockpit--inbox-buffer-name)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (eq major-mode 'chaplet-list-mode)
            (condition-case nil
                (chaplet-list-refresh)
              (error nil))))))))

(defun maduin-cockpit--start-inbox-timer ()
  "Ensure the opt-in inbox refresh timer matches current configuration."
  (if (null maduin-cockpit-inbox-refresh-interval)
      (when maduin-cockpit--inbox-timer
        (cancel-timer maduin-cockpit--inbox-timer)
        (setq maduin-cockpit--inbox-timer nil))
    (unless (timerp maduin-cockpit--inbox-timer)
      (setq maduin-cockpit--inbox-timer
            (run-at-time maduin-cockpit-inbox-refresh-interval
                         maduin-cockpit-inbox-refresh-interval
                         #'maduin-cockpit--inbox-auto-refresh)))))

(defun maduin-cockpit--inbox-auto-refresh ()
  "Refresh the inbox while its buffer has a live window, else stop its timer."
  (let ((buf (get-buffer maduin-cockpit--inbox-buffer-name)))
    (if (and (buffer-live-p buf) (get-buffer-window buf))
        (maduin-cockpit--inbox-refresh)
      (when maduin-cockpit--inbox-timer
        (cancel-timer maduin-cockpit--inbox-timer)
        (setq maduin-cockpit--inbox-timer nil)))))

(defun maduin-cockpit-inbox ()
  "Select and refresh the embedded chaplet inbox window, when present.
When the inbox is absent, message politely and do nothing."
  (interactive)
  (let ((win (get-buffer-window maduin-cockpit--inbox-buffer-name)))
    (if (window-live-p win)
        (progn
          (select-window win)
          (maduin-cockpit--inbox-refresh))
      (message "maduin-cockpit: no inbox present"))))

(defun maduin-cockpit--invalidate-render-signatures (&rest _ignored)
  "Force the next refresh to repaint every live cockpit buffer."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (local-variable-p 'maduin-cockpit--render-signature buffer))
      (with-current-buffer buffer
        (setq-local maduin-cockpit--render-signature nil)))))

(defun maduin-cockpit--schedule-refresh ()
  "Request one leading or trailing cockpit render.
Visible buffers render on a zero-delay timer when the previous render is old
enough.  Events arriving during the minimum interval retain one trailing timer
rather than cancelling and re-arming it, so a stream cannot starve rendering."
  (condition-case nil
      (let ((buf (get-buffer maduin-cockpit-buffer-name)))
        (if (not (and buf (get-buffer-window buf 'visible)))
            (when maduin-cockpit--pending-render
              (cancel-timer maduin-cockpit--pending-render)
              (setq maduin-cockpit--pending-render nil))
          (unless (timerp maduin-cockpit--pending-render)
            (let* ((now (funcall maduin-cockpit--now-fn))
                   (elapsed (and maduin-cockpit--last-render
                                 (- now maduin-cockpit--last-render)))
                   (delay (if (and elapsed
                                   (< elapsed maduin-cockpit-min-render-interval))
                              (- maduin-cockpit-min-render-interval elapsed)
                            0)))
              (setq maduin-cockpit--pending-render
                    (run-at-time delay nil
                                 #'maduin-cockpit--run-scheduled-refresh))))))
    (error nil)))

(defun maduin-cockpit--run-scheduled-refresh ()
  "Run an armed cockpit render, always releasing the scheduler afterwards."
  (unwind-protect
      (condition-case nil
          (let ((buf (get-buffer maduin-cockpit-buffer-name)))
            (when (and buf (get-buffer-window buf 'visible))
              (with-current-buffer buf
                (maduin-pipeline-status-refresh #'maduin-cockpit--schedule-refresh)
                (maduin-cockpit-refresh))))
        (error nil))
    (setq maduin-cockpit--pending-render nil)))

(defun maduin-cockpit--on-complete (_sid _status)
  "Invalidate task titles and nudge a cockpit refresh after session completion.
Added to `maduin-session-on-complete-hook' (SID STATUS are ignored)."
  (maduin-state-invalidate 'titles)
  (condition-case nil
      (run-hook-with-args 'maduin-cockpit-refresh-hook)
    (error nil)))

(defun maduin-cockpit--on-window-change (&optional _frame)
  "Request a scheduled refresh when the cockpit becomes selected.
The shared scheduler handles every throttle and coalescing decision."
  (condition-case nil
      (when (and (get-buffer maduin-cockpit-buffer-name)
                 (eq (window-buffer (selected-window))
                     (get-buffer maduin-cockpit-buffer-name)))
        (maduin-cockpit--schedule-refresh))
    (error nil)))

(defun maduin-cockpit--register-live-updates ()
  "Register cockpit live-update hooks once (idempotent).
Wires the refresh-hook consumer, the session completion nudge, and the
focus refresh (when `window-buffer-change-functions' is available;
older Emacs falls back to the timer-only poll)."
  (add-hook 'maduin-cockpit-refresh-hook #'maduin-cockpit--schedule-refresh)
  (add-hook 'maduin-state-invalidate-hook
            #'maduin-cockpit--invalidate-render-signatures)
  (add-hook 'maduin-cockpit-face-adapt-hook
            #'maduin-cockpit--invalidate-render-signatures)
  (unless (memq #'maduin-cockpit--on-complete maduin-session-on-complete-hook)
    (add-hook 'maduin-session-on-complete-hook #'maduin-cockpit--on-complete))
  (when (boundp 'window-buffer-change-functions)
    (add-hook 'window-buffer-change-functions #'maduin-cockpit--on-window-change)))

(provide 'maduin-cockpit)

;;; maduin-cockpit.el ends here
