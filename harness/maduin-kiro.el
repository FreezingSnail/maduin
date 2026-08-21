;;; maduin-kiro.el --- Kiro CLI backend adapter  -*- lexical-binding: t; -*-

;;; Commentary:

;; Runs Kiro's non-interactive chat command in an isolated worktree.  Kiro
;; does not expose session export or deletion commands, so this adapter owns
;; local process state and obtains diffs from Git in the task worktree.

;;; Code:

(require 'cl-lib)
(require 'ansi-color)
(require 'maduin-backend)
(require 'maduin-session)

(defconst maduin-kiro--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the Kiro backend adapter.")

(defvar maduin-kiro-command "kiro-cli-chat"
  "Executable name for the Kiro chat CLI.")

(defvar maduin-kiro--registry (make-hash-table :test #'equal)
  "Map opaque Kiro handles to process-state plists.")

(defvar maduin-kiro--seq 0
  "Monotonic counter used to generate opaque Kiro handles.")

(defun maduin-kiro--agent-valid-p (agent)
  "Return non-nil when AGENT is empty or names an installed Kiro agent."
  (or (null agent)
      (and (stringp agent)
           (string-empty-p agent))
      (and (stringp agent)
           (file-exists-p
            (expand-file-name (concat "agents/kiro/" agent ".json")
                              maduin-kiro--dir)))))

(defun maduin-kiro--model-valid-p (model)
  "Return non-nil when MODEL can be passed safely to Kiro."
  (and (stringp model)
       (not (string-empty-p model))
       (not (string-match-p "/" model))))

(defun maduin-kiro--strip-ansi (text)
  "Return TEXT with terminal escape sequences removed."
  (ansi-color-filter-apply (or text "")))

(defun maduin-kiro--failure-tail-p (output)
  "Return non-nil when OUTPUT ends in a Kiro quota or auth failure."
  (let ((tail (substring output (max 0 (- (length output) 2048)))))
    (string-match-p
     "\\b\\(?:usage\\(?:[- ]?limit\\| exceeded\\)?\\|credit\\(?:[- ]?limit\\|s\\)?\\|auth\\(?:entication\\|orization\\)?\\|unauthorized\\|not authenticated\\|invalid api key\\)\\b"
     (downcase tail))))

(defun maduin-kiro--entry (handle)
  "Return local process-state entry for HANDLE."
  (gethash handle maduin-kiro--registry))

(defun maduin-kiro--put-entry (handle entry)
  "Store ENTRY as local process state for HANDLE."
  (puthash handle entry maduin-kiro--registry))

(defun maduin-kiro--run-sentinel (process _event)
  "Finalize Kiro PROCESS once it reaches an exit or signal state."
  (when (memq (process-status process) '(exit signal))
    (let* ((handle (process-get process 'maduin-kiro-handle))
           (entry (and handle (maduin-kiro--entry handle))))
      (when (and entry (not (plist-get entry :done)))
        (let* ((buffer (plist-get entry :buffer))
               (output (maduin-kiro--strip-ansi
                        (if (buffer-live-p buffer)
                            (with-current-buffer buffer (buffer-string))
                          "")))
               (completed (and (eq (process-status process) 'exit)
                               (zerop (process-exit-status process))
                               (not (string-empty-p (string-trim output)))
                               (not (maduin-kiro--failure-tail-p output))))
               (status (if completed 'completed 'failed)))
          (setq entry (plist-put entry :output output))
          (setq entry (plist-put entry :status status))
          ;; Mark before hooks: a hook may synchronously revisit this handle.
          (setq entry (plist-put entry :done t))
          (maduin-kiro--put-entry handle entry)
          (run-hook-with-args 'maduin-session-on-complete-hook handle status))))))

(defun maduin-kiro-run (workdir model agent plan)
  "Run PLAN through Kiro in WORKDIR with MODEL and optional AGENT.
Return an opaque handle, or nil without spawning when the agent or model is
invalid, the executable is absent, or process creation fails."
  (when (and (maduin-kiro--agent-valid-p agent)
             (maduin-kiro--model-valid-p model)
             (stringp plan)
             (executable-find maduin-kiro-command))
    (let* ((handle (format "maduin-kiro-%d" (cl-incf maduin-kiro--seq)))
           (buffer (generate-new-buffer (format " *%s*" handle)))
           (command (append (list maduin-kiro-command "chat" "--no-interactive")
                            (unless (or (null agent) (string-empty-p agent))
                              (list "--agent" agent))
                            (list "--model" model "--trust-all-tools" plan)))
           (default-directory (file-name-as-directory (expand-file-name workdir)))
           (process (condition-case nil
                        (make-process :name handle
                                      :buffer buffer
                                      :command command
                                      :sentinel #'maduin-kiro--run-sentinel
                                      :noquery t)
                      (error nil))))
      (if (not process)
          (progn
            (kill-buffer buffer)
            nil)
        (process-put process 'maduin-kiro-handle handle)
        (maduin-kiro--put-entry
         handle (list :process process :buffer buffer :workdir default-directory
                      :status 'running :done nil))
        handle))))

(defun maduin-kiro-tui (root model agent prompt)
  "Start Kiro's non-interactive chat command at ROOT for PROMPT.
Kiro exposes no separate TUI process contract, so this shares `maduin-kiro-run'."
  (maduin-kiro-run root model agent prompt))

(defun maduin-kiro-complete-p (handle)
  "Return `running', `completed', or `failed' for HANDLE.
Unknown handles and dead processes that escaped their sentinel are failed."
  (let ((entry (maduin-kiro--entry handle)))
    (cond
     ((not entry) 'failed)
     ((memq (plist-get entry :status) '(completed failed))
      (plist-get entry :status))
     ((process-live-p (plist-get entry :process)) 'running)
     (t 'failed))))

(defun maduin-kiro--git (workdir &rest arguments)
  "Run Git ARGUMENTS in WORKDIR and return (STATUS . OUTPUT), or nil."
  (condition-case nil
      (let ((default-directory workdir))
        (with-temp-buffer
          (let ((status (apply #'process-file "git" nil t nil arguments)))
            (cons status (buffer-string)))))
    (error nil)))

(defun maduin-kiro--git-output (workdir &rest arguments)
  "Return Git ARGUMENTS output in WORKDIR, retaining nonzero diff output."
  (let ((result (apply #'maduin-kiro--git workdir arguments)))
    (and result (cdr result))))

(defun maduin-kiro-diff (handle)
  "Return tracked, staged, and untracked Git diffs for HANDLE's worktree."
  (let ((entry (maduin-kiro--entry handle)))
    (when entry
      (let* ((workdir (plist-get entry :workdir))
             (unstaged (maduin-kiro--git-output workdir "diff" "--no-ext-diff"))
             (staged (maduin-kiro--git-output workdir "diff" "--cached" "--no-ext-diff"))
             (names (maduin-kiro--git-output
                     workdir "ls-files" "--others" "--exclude-standard" "-z"))
             (untracked
              (mapconcat
               (lambda (name)
                 (or (maduin-kiro--git-output
                      workdir "diff" "--no-index" "--" "/dev/null" name)
                     ""))
               (split-string (or names "") "\0" t)
               "")))
        (concat (or unstaged "") (or staged "") untracked)))))

(defun maduin-kiro-delete (handle)
  "Kill HANDLE's local process and remove all local state.
Kiro has no export or session-delete CLI; this function never invokes one."
  (let ((entry (maduin-kiro--entry handle)))
    (when entry
      (setq entry (plist-put entry :done t))
      (setq entry (plist-put entry :status 'failed))
      (maduin-kiro--put-entry handle entry)
      (let ((process (plist-get entry :process))
            (buffer (plist-get entry :buffer)))
        (when (process-live-p process)
          (delete-process process))
        (remhash handle maduin-kiro--registry)
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      t)))

(maduin-backend-register
 'kiro
 (list :executable maduin-kiro-command
       :run-fn #'maduin-kiro-run
       :tui-fn #'maduin-kiro-tui
       :complete-p-fn #'maduin-kiro-complete-p
       :diff-fn #'maduin-kiro-diff
       :delete-fn #'maduin-kiro-delete))

(provide 'maduin-kiro)

;;; maduin-kiro.el ends here
