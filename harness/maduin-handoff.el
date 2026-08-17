;;; maduin-handoff.el --- graceful session closure  -*- lexical-binding: t; -*-

;;; Commentary:

;; Anti-clonking device.  Agents close their own day: write a handoff
;; diary under .agents/handoff/{seat}.md, then wake fresh with
;; continuity.  Never force /exit.

;;; Code:

(require 'cl-lib)

(defconst maduin-handoff--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-handoff.el.")

;; Ensure sibling harness modules resolve when loaded directly.
(add-to-list 'load-path maduin-handoff--dir)

(require 'maduin-config)

(defun maduin-handoff-cache-path (seat-name)
  "Return handoff cache file path for SEAT-NAME.
Path is .agents/handoff/SEAT-NAME.md relative to the project root."
  (expand-file-name
   (format ".agents/handoff/%s.md" seat-name)
   (maduin-project-root)))

(defun maduin-handoff-read (seat-name)
  "Return handoff cache content for SEAT-NAME as string.
Return nil when the cache file does not exist."
  (let ((path (maduin-handoff-cache-path seat-name)))
    (when (and (file-exists-p path)
               (file-readable-p path))
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

(defun maduin-handoff-write (seat-name content)
  "Write CONTENT to handoff cache for SEAT-NAME.
Create .agents/handoff/ when missing.  Return t on success, nil on failure."
  (condition-case nil
      (let* ((path (maduin-handoff-cache-path seat-name))
             (dir (file-name-directory path)))
        (make-directory dir t)
        (with-temp-buffer
          (insert content)
          (write-region (point-min) (point-max) path nil 'quiet))
        t)
    (error nil)))

(provide 'maduin-handoff)

;;; maduin-handoff.el ends here