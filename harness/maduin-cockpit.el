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
(require 'maduin-config)
(require 'maduin-bd-bridge)
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

(defvar maduin-cockpit-refresh-hook nil
  "Hook run to request a cockpit refresh.
External modules (dispatch, session) run this hook to nudge a refresh
without requiring maduin-cockpit.  Refresh is scheduled on an idle
timer and only happens while the cockpit buffer is visible.")

(defvar maduin-cockpit--idle-timer nil
  "Single-shot idle timer scheduled by `maduin-cockpit--schedule-refresh'.")

(defvar maduin-cockpit--last-refresh nil
  "Float-time of the last cockpit refresh, or nil when never refreshed.
Set by `maduin-cockpit-refresh'; consulted by
`maduin-cockpit--refresh-throttled-p' to debounce focus-driven
refreshes (`maduin-cockpit--on-window-change').")

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

(defvar maduin-cockpit--title-cache nil
  "Alist ((TASK-ID . TITLE) ...) caching bd task titles.
Titles are immutable during a task lifetime, so the cache persists
across refreshes; it is cleared on task completion via
`maduin-cockpit--on-complete'.")

(defvar-local maduin-cockpit--header-cache ""
  "Cached header line rendered by `maduin-cockpit--render-header'.")

(defvar-local maduin-cockpit--header-installed nil
  "Non-nil after the cockpit has installed its header line form.")

(defun maduin-cockpit--task-title (task-id)
  "Return title string for TASK-ID via `bd show', or nil on failure.
Results are cached in `maduin-cockpit--title-cache'; failures are not.
Tolerates either an object or an array shape in the JSON output."
  (when task-id
    (or (cdr (assoc task-id maduin-cockpit--title-cache))
        (let* ((res (maduin-bd--call "bd" "show" task-id "--json"))
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
         (role (maduin-cockpit--seat-role seat)))
    (list :seat seat
          :role (and entry (plist-get entry :role))
          :status (if entry
                      (or (plist-get entry :status) 'working)
                    (and (eq role 'concierge)
                         (maduin-cockpit--concierge-live-p seat)
                         'discussing))
          :task-id (and entry (plist-get entry :task))
          :task-title (maduin-cockpit--task-title
                       (and entry (plist-get entry :task)))
          :model (and entry (plist-get entry :model))
          :backend (if entry
                       (plist-get entry :backend)
                     (and role (maduin-config-seat-backend role seat)))
          :uptime (and entry
                       (or (maduin-cockpit--uptime entry)
                           (plist-get entry :uptime)))
          :phase (and entry (plist-get entry :phase)))))

(defun maduin-cockpit--task-string (status)
  "Return \"TASK-ID — TITLE\" from rich STATUS plist, or \"—\"."
  (let ((id (plist-get status :task-id))
        (title (plist-get status :task-title)))
    (cond ((null id) "—")
          (title (format "%s — %s" id title))
          (t (format "%s —" id)))))

(defun maduin-cockpit--uptime-string (status)
  "Return formatted elapsed uptime from STATUS, or \"—\" when absent."
  (let ((uptime (and status (plist-get status :uptime))))
    (if (null uptime)
        "—"
      (let* ((seconds (max 0 (floor uptime)))
             (hours (/ seconds 3600))
             (minutes (% (/ seconds 60) 60))
             (secs (% seconds 60)))
        (if (> hours 0)
            (format "%02d:%02d:%02d" hours minutes secs)
          (format "%02d:%02d" minutes secs))))))

(defun maduin-cockpit--rows ()
  "Return tabulated-list rows for all configured seats."
  (cl-loop for (seat . role) in (maduin-cockpit--seats)
           for st = (maduin-cockpit--seat-status seat)
           collect (list seat
                         (vector seat
                                 (let ((display-role (or (plist-get st :role) role)))
                                   (if (symbolp display-role)
                                       (symbol-name display-role)
                                     display-role))
                                 (maduin-cockpit--status-pill
                                  (plist-get st :status))
                                 (maduin-cockpit--task-string st)
                                 (or (plist-get st :model) "—")
                                 (let ((backend (plist-get st :backend)))
                                   (if backend (symbol-name backend) "—"))
                                 (maduin-cockpit--uptime-string st)
                                 (or (plist-get st :phase) "—")))))

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

(defun maduin-cockpit--idle-p ()
  "Return non-nil when no dispatch work or queued pipeline work exists."
  (condition-case nil
      (and (null maduin-dispatch--active)
           (equal (plist-get (maduin-pipeline-status) :queued) 0))
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

(defun maduin-cockpit--header-string ()
  "Return cached-header content for the current cockpit state."
  (let* ((harness (cdr (assq 'harness maduin-config)))
         (name (or (cdr (assq 'name harness)) "maduin"))
         (version (or (cdr (assq 'version harness)) "—")))
    (format "%s %s · %s · %s"
            name version (maduin-cockpit--run-state)
            (maduin-cockpit--pipeline-summary))))

(defun maduin-cockpit--render-header ()
  "Install the cheap header evaluator and update its cached string."
  (unless maduin-cockpit--header-installed
    (setq-local header-line-format '((:eval maduin-cockpit--header-cache)))
    (setq-local maduin-cockpit--header-installed t))
  (setq-local maduin-cockpit--header-cache (maduin-cockpit--header-string)))

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
                  '("Activity" 12 t)))))

(defun maduin-cockpit--print-rows ()
  "Update table entries and print them while retaining the current row."
  (setq tabulated-list-entries (maduin-cockpit--rows))
  (tabulated-list-print t))

(defun maduin-cockpit--render-footer ()
  "Render the empty-state cue after the seat table without moving point."
  (condition-case nil
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (when (maduin-cockpit--idle-p)
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
    (maduin-cockpit-refresh)
    (maduin-cockpit--start-timer)
    (maduin-cockpit--embed-inbox)
    buf))

(defun maduin-cockpit-refresh ()
  "Refresh cockpit rows, cached header, and empty-state cue without jumping.
The task-title cache persists across refreshes (titles are immutable
within a task lifetime) and is only cleared on task completion.  Records
the refresh time in `maduin-cockpit--last-refresh' so the focus-driven
path can throttle rapid window switches."
  (interactive)
  (setq maduin-cockpit--last-refresh (float-time))
  (let* ((window (get-buffer-window (current-buffer) 'visible))
         (window-start (and (window-live-p window) (window-start window))))
    (maduin-cockpit--ensure-format)
    (maduin-cockpit--print-rows)
    (maduin-cockpit--render-header)
    (maduin-cockpit--render-footer)
    (when (and window-start (window-live-p window))
      (set-window-start window window-start t))))

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
(hidden but alive) so work in other buffers is not interrupted.
The embedded inbox is refreshed only when `chaplet-auto-refresh' is
non-nil; chaplet refreshes the inbox itself on focus, so refreshing
it here unconditionally double-refreshes."
  (let ((buf (get-buffer maduin-cockpit-buffer-name)))
    (if (or (null buf) (null (get-buffer-window buf 'visible)))
        (maduin-cockpit--stop-timer)
      (with-current-buffer buf
        (maduin-cockpit-refresh)
        (when chaplet-auto-refresh
          (maduin-cockpit--inbox-refresh))))))

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

(defun maduin-cockpit-inbox ()
  "Select the embedded chaplet inbox window, when present.
When the inbox is absent, message politely and do nothing."
  (interactive)
  (let ((win (get-buffer-window maduin-cockpit--inbox-buffer-name)))
    (if (window-live-p win)
        (select-window win)
      (message "maduin-cockpit: no inbox present"))))

(defun maduin-cockpit--schedule-refresh ()
  "Schedule a debounced single-shot idle-timer refresh of the cockpit.
No-op when the cockpit buffer is absent or not visible (buried/hidden),
so work in other buffers is not interrupted.  Wrapped in condition-case
so a missing buffer or timer error never signals."
  (condition-case nil
      (let ((buf (get-buffer maduin-cockpit-buffer-name)))
        (when (and buf (get-buffer-window buf 'visible))
          (when (timerp maduin-cockpit--idle-timer)
            (cancel-timer maduin-cockpit--idle-timer))
          (setq maduin-cockpit--idle-timer
                (run-with-idle-timer 0.2 nil #'maduin-cockpit--idle-refresh))))
    (error nil)))

(defun maduin-cockpit--idle-refresh ()
  "Refresh the cockpit from the scheduled idle timer, guarded.
Clears the timer and refreshes only while the cockpit buffer is visible;
a buried or absent buffer is a no-op."
  (setq maduin-cockpit--idle-timer nil)
  (condition-case nil
      (let ((buf (get-buffer maduin-cockpit-buffer-name)))
        (when (and buf (get-buffer-window buf 'visible))
          (with-current-buffer buf
            (maduin-cockpit-refresh))))
    (error nil)))

(defun maduin-cockpit--on-complete (_sid _status)
  "Clear the task-title cache and nudge a cockpit refresh when an
autonomous session reaches a terminal state.
Added to `maduin-session-on-complete-hook' (SID STATUS are ignored)."
  (setq maduin-cockpit--title-cache nil)
  (condition-case nil
      (run-hook-with-args 'maduin-cockpit-refresh-hook)
    (error nil)))

(defun maduin-cockpit--refresh-throttled-p (&optional now)
  "Return non-nil when a cockpit refresh should be skipped as throttled.
True when less than `maduin-cockpit-refresh-interval' seconds have
elapsed since `maduin-cockpit--last-refresh' — i.e. the cockpit was
already visible and freshly refreshed.  NOW (float) defaults to
`float-time'."
  (let ((last maduin-cockpit--last-refresh))
    (and last
         (< (- (or now (float-time)) last)
            maduin-cockpit-refresh-interval))))

(defun maduin-cockpit--on-window-change (&optional _frame)
  "Refresh the cockpit when it becomes the selected window's buffer.
Per-event cheap guard: only acts when the selected window shows the
cockpit buffer, avoiding a refresh storm on unrelated window changes.
Debounced: scheduling is skipped when a refresh happened less than
`maduin-cockpit-refresh-interval' seconds ago (the cockpit was already
visible and freshly refreshed), so rapid window switches queue at most
one refresh within the interval."
  (condition-case nil
      (when (and (get-buffer maduin-cockpit-buffer-name)
                 (eq (window-buffer (selected-window))
                     (get-buffer maduin-cockpit-buffer-name))
                 (not (maduin-cockpit--refresh-throttled-p)))
        (run-hook-with-args 'maduin-cockpit-refresh-hook))
    (error nil)))

(defun maduin-cockpit--register-live-updates ()
  "Register cockpit live-update hooks once (idempotent).
Wires the refresh-hook consumer, the session completion nudge, and the
focus refresh (when `window-buffer-change-functions' is available;
older Emacs falls back to the timer-only poll)."
  (add-hook 'maduin-cockpit-refresh-hook #'maduin-cockpit--schedule-refresh)
  (unless (memq #'maduin-cockpit--on-complete maduin-session-on-complete-hook)
    (add-hook 'maduin-session-on-complete-hook #'maduin-cockpit--on-complete))
  (when (boundp 'window-buffer-change-functions)
    (add-hook 'window-buffer-change-functions #'maduin-cockpit--on-window-change)))

(provide 'maduin-cockpit)

;;; maduin-cockpit.el ends here
