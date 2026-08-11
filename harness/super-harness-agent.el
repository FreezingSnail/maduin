;;; super-harness-agent.el --- agent lifecycle: spawn, prime, kill, restart  -*- lexical-binding: t; -*-

;;; Commentary:

;; Agent lifecycle for super-harness.  Each agent seat is backed by a
;; session buffer (super-harness-session.el) holding an opencode
;; subprocess.  Spawning creates the session, then primes the agent
;; with role template, brain files, handoff cache and bd context.

;;; Code:

(require 'cl-lib)

(defconst super-harness-agent--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing super-harness-agent.el.")

;;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path super-harness-agent--dir)

(require 'super-harness-config)
(require 'super-harness-session)
(require 'super-harness-brain)
(require 'super-harness-workspace)

;; super-harness-bd-bridge.el may not exist yet; guard the require.
(condition-case nil
    (require 'super-harness-bd-bridge)
  (error nil))

(defvar super-harness-agent-priming-hook nil
  "Hooks run after priming an agent.  Each hook receives the seat name.")

(defun super-harness-agent--config-get (key)
  "Return KEY from super-harness-config, or nil when unset."
  (when (and (boundp 'super-harness-config)
             super-harness-config)
    (cdr (assq key super-harness-config))))

(defun super-harness-agent--template (role)
  "Return role template text for ROLE (crew or fleet), or nil.
Reads templates/crew-prompt.txt or templates/fleet-prompt.txt."
  (let* ((kind (if (string= role "fleet") "fleet" "crew"))
         (path (expand-file-name
                (format "templates/%s-prompt.txt" kind)
                super-harness-agent--dir)))
    (when (and (file-exists-p path)
               (file-readable-p path))
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

(defun super-harness-agent--substitute (text seat-name)
  "Replace {name}, {seat}, {model} placeholders in TEXT for SEAT-NAME."
  (let* ((model (or (super-harness-agent--config-get 'model) "default"))
         (out (replace-regexp-in-string "{name}" seat-name text t t)))
    (setq out (replace-regexp-in-string "{seat}" seat-name out t t))
    (replace-regexp-in-string "{model}" model out t t)))

(defun super-harness-agent--handoff (seat-name dir)
  "Return handoff cache text for SEAT-NAME, or nil.
Prefers super-harness-handoff-read when loaded; else reads
.agents/handoff/SEAT-NAME.md under DIR directly."
  (let ((path (expand-file-name
               (format ".agents/handoff/%s.md" seat-name)
               (or dir default-directory))))
    (cond
     ((fboundp 'super-harness-handoff-read)
      (super-harness-handoff-read seat-name))
     ((file-readable-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))
     (t nil))))

(defun super-harness-agent--priming-text (seat-name role)
  "Build full priming text for SEAT-NAME with ROLE."
  (let ((parts nil))
    (let ((tmpl (super-harness-agent--template role)))
      (when tmpl
        (push (super-harness-agent--substitute tmpl seat-name) parts)))
    (let ((files (super-harness-brain--prime-files))
          (brain-text (format "\nProject brain loaded for seat %s:\n" seat-name)))
      (dolist (file files)
        (let ((content (super-harness-brain-read file)))
          (setq brain-text (format "%s  - %s:\n" brain-text file))
          (when content
            (setq brain-text (format "%s```markdown\n%s\n```\n"
                                     brain-text content)))))
      (setq brain-text (format "%s\n" brain-text))
      (push brain-text parts))
    (let ((handoff (super-harness-agent--handoff
                    seat-name super-harness-workdir)))
      (when handoff
        (push (format "\nHandoff from last session:\n```markdown\n%s\n```\n"
                      handoff)
              parts)))
    (when (fboundp 'super-harness-bd-prime)
      (let ((bd-text (super-harness-bd-prime)))
        (when (and bd-text (not (string-empty-p bd-text)))
          (push (format "\nbd context:\n```\n%s\n```\n" bd-text) parts))))
    (string-join (nreverse parts) "\n")))

(defun super-harness-agent-prime (seat-name &optional role)
  "Prime agent for SEAT-NAME with ROLE by injecting priming text.
Send text via process-send-string when the process is alive;
otherwise insert into the agent buffer.  Run
`super-harness-agent-priming-hook' with SEAT-NAME after priming."
  (let* ((buf (super-harness-session--buffer seat-name))
         (proc (and buf (get-buffer-process buf)))
         (role (or role (and buf (buffer-local-value 'super-harness-role buf))
                   "crew"))
         (text (super-harness-agent--priming-text seat-name role)))
    (when buf
      (with-current-buffer buf
        (if (and proc (process-live-p proc))
            (process-send-string proc text)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert text))))
      (run-hook-with-args 'super-harness-agent-priming-hook seat-name))))

(defun super-harness-agent-spawn (seat role model _workdir)
  "Spawn agent SEAT with ROLE and MODEL in its seat worktree.
The worktree is ensured (created when missing); WORKDIR argument is
kept for call-site compatibility but the worktree path wins.
Delegate to super-harness-session-create, prime the new agent, and
return its process (or nil on failure)."
  (condition-case err
      (let* ((dir (or (super-harness-workspace-ensure seat)
                      (super-harness-workspace-path seat)))
             (default-directory (or dir default-directory))
             (buf (super-harness-session-create seat role model dir)))
        (when buf
          (super-harness-agent-prime seat role)
          (get-buffer-process buf)))
    (error
     (message "super-harness: spawn %s failed: %s" seat err)
     nil)))

(defun super-harness-agent-kill (seat-name)
  "Kill agent session for SEAT-NAME.  Return non-nil when anything was killed."
  (super-harness-session-kill seat-name))

(defun super-harness-agent-status (seat-name)
  "Return plist (:status :task :uptime :model :role) for SEAT-NAME.
Uptime is seconds since session start.  Return nil when no session."
  (let ((buf (super-harness-session--buffer seat-name)))
    (when buf
      (with-current-buffer buf
        (list :status super-harness-status
              :task super-harness-current-task
              :uptime (and super-harness-started-at
                           (- (float-time) super-harness-started-at))
              :model super-harness-model
              :role super-harness-role)))))

(defun super-harness-agent-restart (seat-name)
  "Restart agent for SEAT-NAME with the same config.
Kill the current session, then spawn again with seat, role, model and
workdir read from the session buffer.  Return the new process or nil."
  (let* ((buf (super-harness-session--buffer seat-name))
         (cfg (and buf
                   (with-current-buffer buf
                     (list super-harness-seat super-harness-role
                           super-harness-model super-harness-workdir)))))
    (when (and cfg (car cfg))
      (super-harness-agent-kill seat-name)
      (apply #'super-harness-agent-spawn cfg))))

(provide 'super-harness-agent)

;;; super-harness-agent.el ends here
