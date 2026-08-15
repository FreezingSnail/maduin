;;; maduin-terminal.el --- interactive opencode TUI in a terminal buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; Interactive session substrate.  Opens an opencode TUI inside an
;; Emacs terminal buffer (vterm preferred, `term' fallback) for
;; back-and-forth conversations (concierge, designer drop-in).
;; Dismiss exports the conversation to .agents/handoff/SEAT.md BEFORE
;; killing the buffer, so nothing is lost.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'term)

(defconst maduin-terminal--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-terminal.el.")

;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path maduin-terminal--dir)

(require 'maduin-config)

;; maduin-handoff.el provides maduin-handoff-write; reuse it when
;; available, fall back to a direct write otherwise.
(condition-case nil
    (require 'maduin-handoff)
  (error nil))

;; Buffer-local state.
(defvar maduin-terminal-seat nil)
(defvar maduin-terminal-role nil)
(defvar maduin-terminal-model nil)
(defvar maduin-terminal-root nil)
(defvar maduin-terminal-session-id nil)
(defvar maduin-terminal-started-at nil)
(defvar maduin-terminal-known-ids nil)

;;; Pure helpers (unit-testable)

(defun maduin-terminal--role-name (role)
  "Return ROLE as a string (symbols get `symbol-name')."
  (cond ((symbolp role) (symbol-name role))
        ((stringp role) role)
        (t (format "%s" role))))

(defun maduin-terminal--buffer-name (role seat)
  "Buffer name for interactive session ROLE/SEAT."
  (format "*maduin/%s-%s*" (maduin-terminal--role-name role) seat))

(defun maduin-terminal--choose-backend (vterm-available)
  "Return `vterm when VTERM-AVAILABLE is non-nil, else `term."
  (if vterm-available 'vterm 'term))

(defun maduin-terminal--backend ()
  "Detect terminal backend: `vterm when loadable, else `term."
  (maduin-terminal--choose-backend
   (condition-case nil
       (and (require 'vterm nil t) t)
     (error nil))))

(defun maduin-terminal--template (role-name)
  "Return role template text for ROLE-NAME, or nil.
Reads templates/ROLE-NAME-prompt.txt under the harness dir."
  (let ((path (expand-file-name
               (format "templates/%s-prompt.txt" role-name)
               maduin-terminal--dir)))
    (when (and (file-exists-p path)
               (file-readable-p path))
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

(defun maduin-terminal--substitute (text seat role model)
  "Replace {name}/{seat}/{role}/{model} placeholders in TEXT."
  (let ((out (replace-regexp-in-string "{name}" seat text t t)))
    (setq out (replace-regexp-in-string "{seat}" seat out t t))
    (setq out (replace-regexp-in-string "{role}" role out t t))
    (replace-regexp-in-string "{model}" model out t t)))

(defun maduin-terminal--prompt (seat role model)
  "Return priming prompt string for SEAT with ROLE and MODEL.
Reads templates/ROLE-prompt.txt when present; else a generic inline
prime string."
  (let* ((role-name (maduin-terminal--role-name role))
         (tmpl (maduin-terminal--template role-name)))
    (if tmpl
        (maduin-terminal--substitute tmpl seat role-name model)
      (format "You are %s, the %s (model %s). Take a beat, then respond."
              seat role-name model))))

(defun maduin-terminal--command-line (root model prompt &optional exe)
  "Return a single shell command line launching the opencode TUI.
EXE defaults to the opencode executable."
  (mapconcat #'identity
             (list (or exe
                       (or (bound-and-true-p maduin-opencode-command)
                           "opencode"))
                   (shell-quote-argument root)
                   "-m" (shell-quote-argument model)
                   "--prompt" (shell-quote-argument prompt))
             " "))

(defun maduin-terminal--parse-session-ids (json-str root &optional since exclude)
  "Parse JSON-STR (`opencode session list --format json') and return
a list of (created . id) pairs for sessions whose directory matches
ROOT.  SINCE (epoch seconds) is a minimum created time; EXCLUDE is a
list of ids to skip.  Sorted newest first."
  (condition-case nil
      (let* ((json-object-type 'hash-table)
             (json-array-type 'vector)
             (json-key-type 'string)
             (data (json-read-from-string json-str))
             (root-dir (directory-file-name (expand-file-name root)))
             (since-ms (and since (* since 1000.0)))
             (out nil))
        (when (vectorp data)
          (cl-loop for s across data do
            (let ((dir (and (hash-table-p s) (gethash "directory" s)))
                  (created (and (hash-table-p s) (gethash "created" s)))
                  (id (and (hash-table-p s) (gethash "id" s))))
              (when (and (stringp dir) (stringp id) (numberp created)
                         (equal (directory-file-name (expand-file-name dir))
                                root-dir)
                         (or (null since-ms) (>= created since-ms))
                         (not (member id exclude)))
                (push (cons created id) out)))))
        (sort out (lambda (a b) (> (car a) (car b)))))
    (error nil)))

(defun maduin-terminal--run (&rest args)
  "Run opencode with ARGS; return stdout string, or nil on failure."
  (let ((exe (or (bound-and-true-p maduin-opencode-command) "opencode")))
    (with-temp-buffer
      (if (zerop (apply #'call-process exe nil t nil args))
          (buffer-string)
        nil))))

(defun maduin-terminal--session-ids (root &optional since)
  "Return list of opencode session ids under ROOT (newest first)."
  (mapcar #'cdr
          (maduin-terminal--parse-session-ids
           (maduin-terminal--run "session" "list" "--format" "json")
           root since)))

(defun maduin-terminal--session-id (root since exclude)
  "Return newest opencode session id under ROOT, or nil.
SINCE is a minimum created time (epoch seconds); EXCLUDE ids to skip."
  (let ((pairs (maduin-terminal--parse-session-ids
                (maduin-terminal--run "session" "list" "--format" "json")
                root since exclude)))
    (cdar pairs)))

(defun maduin-terminal--export (sid)
  "Run `opencode export SID'; return output string, or nil."
  (let ((out (maduin-terminal--run "export" sid)))
    (and (not (string-empty-p out)) out)))

(defun maduin-terminal--handoff-note (sid json)
  "Return a markdown handoff note from an opencode export (SID/JSON)."
  (format "<!-- maduin interactive session export -->\n# Interactive session %s\n\nExported: %s\n\n```json\n%s\n```\n"
          sid (format-time-string "%Y-%m-%dT%H:%M:%S%z" (current-time)) json))

;;; Terminal backend I/O

(defun maduin-terminal--open-buffer (backend role seat)
  "Create a terminal buffer for ROLE/SEAT using BACKEND; return it."
  (let ((name (maduin-terminal--buffer-name role seat)))
    (cond
     ((eq backend 'vterm)
      (unless (fboundp 'vterm)
        (error "maduin: vterm not available"))
      (vterm)
      (rename-buffer name)
      (current-buffer))
     ((eq backend 'term)
      (term nil)
      (rename-buffer name)
      (current-buffer))
     (t (error "maduin: unknown terminal backend %S" backend)))))

(defun maduin-terminal--send (buf backend command)
  "Send COMMAND (a shell line) to terminal BUF via BACKEND."
  (cond
   ((eq backend 'vterm)
    (with-current-buffer buf
      (vterm-send-string command)
      (vterm-send-return)))
   ((eq backend 'term)
    (let ((proc (get-buffer-process buf)))
      (when proc
        (term-send-string proc (concat command "\n")))))))

;;; Handoff / lifecycle helpers

(defun maduin-terminal--find-buffer (seat)
  "Return the interactive terminal buffer for SEAT, or nil."
  (cl-find-if
   (lambda (buf)
     (and (buffer-live-p buf)
          (local-variable-p 'maduin-terminal-seat buf)
          (string= (buffer-local-value 'maduin-terminal-seat buf) seat)))
   (buffer-list)))

(defun maduin-terminal--write-handoff (seat note root)
  "Write NOTE to the handoff cache for SEAT.
Prefer `maduin-handoff-write'; else write .agents/handoff/SEAT.md
under ROOT directly.  Return t on success, nil on failure."
  (if (fboundp 'maduin-handoff-write)
      (maduin-handoff-write seat note)
    (condition-case nil
        (let* ((path (expand-file-name
                      (format ".agents/handoff/%s.md" seat) root))
               (dir (file-name-directory path)))
          (make-directory dir t)
          (with-temp-buffer
            (insert note)
            (write-region (point-min) (point-max) path nil 'quiet))
          t)
      (error nil))))

(defun maduin-terminal--kill-buffer (buf)
  "Kill terminal BUF, silently terminating its process first."
  (when (and buf (buffer-live-p buf))
    (let ((proc (get-buffer-process buf)))
      (when (and proc (process-live-p proc))
        (set-process-query-on-exit-flag proc nil)
        (ignore-errors (kill-process proc))))
    (let ((kill-buffer-query-functions nil))
      (ignore-errors (kill-buffer buf)))))

;;; Public interface

;;;###autoload
(defun maduin-terminal-open (seat role model)
  "Open an interactive opencode TUI for SEAT (ROLE, MODEL) in a
terminal buffer (vterm preferred, term fallback), primed with the role
template.  Return the buffer."
  (let* ((backend (maduin-terminal--backend))
         (root (maduin-project-root))
         (prompt (maduin-terminal--prompt seat role model))
         (cmd (maduin-terminal--command-line root model prompt))
         (buf (maduin-terminal--open-buffer backend role seat)))
    (with-current-buffer buf
      (setq-local maduin-terminal-seat seat)
      (setq-local maduin-terminal-role (maduin-terminal--role-name role))
      (setq-local maduin-terminal-model model)
      (setq-local maduin-terminal-root root)
      (setq-local maduin-terminal-session-id nil)
      (setq-local maduin-terminal-started-at (float-time))
      (setq-local maduin-terminal-known-ids
                  (maduin-terminal--session-ids root)))
    (maduin-terminal--send buf backend cmd)
    buf))

;;;###autoload
(defun maduin-terminal-dismiss (seat)
  "Dismiss the interactive session for SEAT.
Export the opencode conversation to .agents/handoff/SEAT.md, then kill
the terminal buffer.  Return the handoff note string, or nil."
  (let ((buf (maduin-terminal--find-buffer seat)))
    (when buf
      (let* ((root (or (buffer-local-value 'maduin-terminal-root buf)
                       (maduin-project-root)))
             (started (buffer-local-value 'maduin-terminal-started-at buf))
             (known (buffer-local-value 'maduin-terminal-known-ids buf))
             (sid (or (buffer-local-value 'maduin-terminal-session-id buf)
                      (maduin-terminal--session-id root started known)))
             (json (and sid (maduin-terminal--export sid)))
             (note (and json (maduin-terminal--handoff-note sid json))))
        (when note
          (maduin-terminal--write-handoff seat note root))
        (maduin-terminal--kill-buffer buf)
        note))))

;;;###autoload
(defun maduin-terminal-active-p (seat)
  "Return t when SEAT has a live interactive terminal buffer."
  (let ((buf (maduin-terminal--find-buffer seat)))
    (and buf
         (buffer-live-p buf)
         (let ((proc (get-buffer-process buf)))
           (and proc (process-live-p proc))))))

(provide 'maduin-terminal)

;;; maduin-terminal.el ends here
