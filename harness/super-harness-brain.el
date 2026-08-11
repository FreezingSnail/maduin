;;; super-harness-brain.el --- Markdown knowledge base read/write  -*- lexical-binding: t; -*-

;; Brain files live under .agents/brain/ (configurable via
;; super-harness-config brain.path).  Agent priming reads prime-files
;; from config and inserts their content into the current buffer.

(require 'cl-lib)

(require 'super-harness-config nil t)

(defconst super-harness-brain-default-root ".agents/brain"
  "Fallback brain root when super-harness-config is unavailable.")

(defconst super-harness-brain-default-prime-files
  '("architecture.md" "conventions.md")
  "Default prime files when config has no brain.prime-files.")

(defun super-harness-brain--config-get (key)
  "Look up KEY in super-harness-config brain section.
Return nil when config not loaded or key missing."
  (when (and (boundp 'super-harness-config)
             super-harness-config)
    (let ((brain (cdr (assq 'brain super-harness-config))))
      (when brain
        (cdr (assq key brain))))))

(defun super-harness-brain-root ()
  "Return absolute brain root directory."
  (expand-file-name
   (or (super-harness-brain--config-get 'path)
       super-harness-brain-default-root)))

(defun super-harness-brain--expand (file)
  "Expand FILE relative to brain root to an absolute path."
  (expand-file-name file (super-harness-brain-root)))

(defun super-harness-brain-read (file)
  "Return content of FILE (relative to brain root) as string.
Return nil when FILE is missing."
  (let ((path (super-harness-brain--expand file)))
    (when (and (file-exists-p path)
               (file-readable-p path))
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

(defun super-harness-brain-write (file content)
  "Write CONTENT to FILE under brain root, creating parents.
Return t on success, nil on failure."
  (condition-case nil
      (let* ((path (super-harness-brain--expand file))
             (dir (file-name-directory path)))
        (make-directory dir t)
        (with-temp-buffer
          (insert content)
          (write-region (point-min) (point-max) path nil 'quiet))
        t)
    (error nil)))

(defun super-harness-brain-list ()
  "Return list of file paths under brain root, relative and recursive.
Only regular files are included."
  (let* ((root (super-harness-brain-root))
         (root-len (length root)))
    (if (file-directory-p root)
        (cl-remove-if
         (lambda (p) (file-directory-p p))
         (mapcar (lambda (p) (substring p (1+ root-len)))
                 (directory-files-recursively root "")))
      nil)))

(defun super-harness-brain--prime-files ()
  "Return prime file list from config, falling back to default."
  (or (super-harness-brain--config-get 'prime-files)
      super-harness-brain-default-prime-files))

(defun super-harness-brain-prime (seat-name)
  "Insert brain prime files into current buffer for SEAT-NAME.
Reads prime-files from config and inserts each with a header."
  (insert (format "Project brain loaded for seat %s:\n" seat-name))
  (dolist (file (super-harness-brain--prime-files))
    (let ((content (super-harness-brain-read file)))
      (insert (format "  - %s:\n" file))
      (when content
        (insert (format "```markdown\n%s\n```\n" content)))))
  (insert "\n"))

(provide 'super-harness-brain)

;;; super-harness-brain.el ends here
