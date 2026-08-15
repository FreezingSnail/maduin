;;; maduin-brain.el --- Markdown knowledge base read/write  -*- lexical-binding: t; -*-

;; Brain files live under .agents/brain/ (configurable via
;; maduin-config brain.path).  Agent priming reads prime-files
;; from config and inserts their content into the current buffer.

(require 'cl-lib)

(require 'maduin-config nil t)

(defconst maduin-brain-default-root ".agents/brain"
  "Fallback brain root when maduin-config is unavailable.")

(defconst maduin-brain-default-prime-files
  '("architecture.md" "conventions.md")
  "Default prime files when config has no brain.prime-files.")

(defun maduin-brain--config-get (key)
  "Look up KEY in maduin-config brain section.
Return nil when config not loaded or key missing."
  (when (and (boundp 'maduin-config)
             maduin-config)
    (let ((brain (cdr (assq 'brain maduin-config))))
      (when brain
        (cdr (assq key brain))))))

(defun maduin-brain-root ()
  "Return absolute brain root directory."
  (expand-file-name
   (or (maduin-brain--config-get 'path)
       maduin-brain-default-root)))

(defun maduin-brain--expand (file)
  "Expand FILE relative to brain root to an absolute path."
  (expand-file-name file (maduin-brain-root)))

(defun maduin-brain-read (file)
  "Return content of FILE (relative to brain root) as string.
Return nil when FILE is missing."
  (let ((path (maduin-brain--expand file)))
    (when (and (file-exists-p path)
               (file-readable-p path))
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

(defun maduin-brain-write (file content)
  "Write CONTENT to FILE under brain root, creating parents.
Return t on success, nil on failure."
  (condition-case nil
      (let* ((path (maduin-brain--expand file))
             (dir (file-name-directory path)))
        (make-directory dir t)
        (with-temp-buffer
          (insert content)
          (write-region (point-min) (point-max) path nil 'quiet))
        t)
    (error nil)))

(defun maduin-brain-list ()
  "Return list of file paths under brain root, relative and recursive.
Only regular files are included."
  (let* ((root (maduin-brain-root))
         (root-len (length root)))
    (if (file-directory-p root)
        (cl-remove-if
         (lambda (p) (file-directory-p p))
         (mapcar (lambda (p) (substring p (1+ root-len)))
                 (directory-files-recursively root "")))
      nil)))

(defun maduin-brain--prime-files ()
  "Return prime file list from config, falling back to default."
  (or (maduin-brain--config-get 'prime-files)
      maduin-brain-default-prime-files))

(defun maduin-brain-prime (seat-name)
  "Insert brain prime files into current buffer for SEAT-NAME.
Reads prime-files from config and inserts each with a header."
  (insert (format "Project brain loaded for seat %s:\n" seat-name))
  (dolist (file (maduin-brain--prime-files))
    (let ((content (maduin-brain-read file)))
      (insert (format "  - %s:\n" file))
      (when content
        (insert (format "```markdown\n%s\n```\n" content)))))
  (insert "\n"))

(provide 'maduin-brain)

;;; maduin-brain.el ends here
