;;; maduin-agent.el --- agent lifecycle: spawn, prime, kill, restart  -*- lexical-binding: t; -*-

;;; Commentary:

;; Agent lifecycle for maduin.  Each agent seat is backed by a
;; session buffer (maduin-session.el) holding an opencode
;; subprocess.  Spawning creates the session, then primes the agent
;; with role template, brain files, handoff cache and bd context.

;;; Code:

(require 'cl-lib)

(defconst maduin-agent--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-agent.el.")

;;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path maduin-agent--dir)

(require 'maduin-config)
(require 'maduin-session)
(require 'maduin-brain)
(require 'maduin-workspace)

;; maduin-bd-bridge.el may not exist yet; guard the require.
(condition-case nil
    (require 'maduin-bd-bridge)
  (error nil))

(defvar maduin-agent-priming-hook nil
  "Hooks run after priming an agent.  Each hook receives the seat name.")

(defun maduin-agent--config-get (key)
  "Return KEY from maduin-config, or nil when unset."
  (when (and (boundp 'maduin-config)
             maduin-config)
    (cdr (assq key maduin-config))))

(defun maduin-agent--template (role)
  "Return role template text for ROLE (crew or fleet), or nil.
Reads templates/crew-prompt.txt or templates/fleet-prompt.txt."
  (let* ((kind (if (string= role "fleet") "fleet" "crew"))
         (path (expand-file-name
                (format "templates/%s-prompt.txt" kind)
                maduin-agent--dir)))
    (when (and (file-exists-p path)
               (file-readable-p path))
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

(defun maduin-agent--substitute (text seat-name)
  "Replace {name}, {seat}, {model} placeholders in TEXT for SEAT-NAME."
  (let* ((model (or (maduin-agent--config-get 'model) "default"))
         (out (replace-regexp-in-string "{name}" seat-name text t t)))
    (setq out (replace-regexp-in-string "{seat}" seat-name out t t))
    (replace-regexp-in-string "{model}" model out t t)))

(defun maduin-agent--handoff (seat-name dir)
  "Return handoff cache text for SEAT-NAME, or nil.
Prefers maduin-handoff-read when loaded; else reads
.agents/handoff/SEAT-NAME.md under DIR directly."
  (let ((path (expand-file-name
               (format ".agents/handoff/%s.md" seat-name)
               (or dir default-directory))))
    (cond
     ((fboundp 'maduin-handoff-read)
      (maduin-handoff-read seat-name))
     ((file-readable-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))
     (t nil))))

(defun maduin-agent--priming-text (seat-name role)
  "Build full priming text for SEAT-NAME with ROLE."
  (let ((parts nil))
    (let ((tmpl (maduin-agent--template role)))
      (when tmpl
        (push (maduin-agent--substitute tmpl seat-name) parts)))
    (let ((files (maduin-brain--prime-files))
          (brain-text (format "\nProject brain loaded for seat %s:\n" seat-name)))
      (dolist (file files)
        (let ((content (maduin-brain-read file)))
          (setq brain-text (format "%s  - %s:\n" brain-text file))
          (when content
            (setq brain-text (format "%s```markdown\n%s\n```\n"
                                     brain-text content)))))
      (setq brain-text (format "%s\n" brain-text))
      (push brain-text parts))
    (let ((handoff (maduin-agent--handoff
                    seat-name maduin-workdir)))
      (when handoff
        (push (format "\nHandoff from last session:\n```markdown\n%s\n```\n"
                      handoff)
              parts)))
    (when (fboundp 'maduin-bd-prime)
      (let ((bd-text (maduin-bd-prime)))
        (when (and bd-text (not (string-empty-p bd-text)))
          (push (format "\nbd context:\n```\n%s\n```\n" bd-text) parts))))
    (string-join (nreverse parts) "\n")))

(defun maduin-agent-prime (seat-name &optional role)
  "Prime agent for SEAT-NAME with ROLE by injecting priming text.
Send text via process-send-string when the process is alive;
otherwise insert into the agent buffer.  Run
`maduin-agent-priming-hook' with SEAT-NAME after priming."
  (let* ((buf (maduin-session--buffer seat-name))
         (proc (and buf (get-buffer-process buf)))
         (role (or role (and buf (buffer-local-value 'maduin-role buf))
                   "crew"))
         (text (maduin-agent--priming-text seat-name role)))
    (when buf
      (with-current-buffer buf
        (if (and proc (process-live-p proc))
            (process-send-string proc text)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert text))))
      (run-hook-with-args 'maduin-agent-priming-hook seat-name))))

(defun maduin-agent-spawn (seat role model _workdir)
  "Spawn agent SEAT with ROLE and MODEL in its seat worktree.
The worktree is ensured (created when missing); WORKDIR argument is
kept for call-site compatibility but the worktree path wins.
Delegate to maduin-session-create, prime the new agent, and
return its process (or nil on failure)."
  (condition-case err
      (let* ((dir (or (maduin-workspace-ensure seat)
                      (maduin-workspace-path seat)))
             (default-directory (or dir default-directory))
             (buf (maduin-session-create seat role model dir)))
        (when buf
          (maduin-agent-prime seat role)
          (get-buffer-process buf)))
    (error
     (message "maduin: spawn %s failed: %s" seat err)
     nil)))

(defun maduin-agent-kill (seat-name)
  "Kill agent session for SEAT-NAME.  Return non-nil when anything was killed."
  (maduin-session-kill seat-name))

(defun maduin-agent-status (seat-name)
  "Return plist (:status :task :uptime :model :role) for SEAT-NAME.
Uptime is seconds since session start.  Return nil when no session."
  (let ((buf (maduin-session--buffer seat-name)))
    (when buf
      (with-current-buffer buf
        (list :status maduin-status
              :task maduin-current-task
              :uptime (and maduin-started-at
                           (- (float-time) maduin-started-at))
              :model maduin-model
              :role maduin-role)))))

(defun maduin-agent-restart (seat-name)
  "Restart agent for SEAT-NAME with the same config.
Kill the current session, then spawn again with seat, role, model and
workdir read from the session buffer.  Return the new process or nil."
  (let* ((buf (maduin-session--buffer seat-name))
         (cfg (and buf
                   (with-current-buffer buf
                     (list maduin-seat maduin-role
                           maduin-model maduin-workdir)))))
    (when (and cfg (car cfg))
      (maduin-agent-kill seat-name)
      (apply #'maduin-agent-spawn cfg))))

(provide 'maduin-agent)

;;; maduin-agent.el ends here
