;;; maduin-stamp.el --- commit provenance trailer vocabulary  -*- lexical-binding: t; -*-

;;; Commentary:

;; Pure construction and presentation of maduin provenance trailers.  Git and
;; bd integration intentionally live in their respective callers.

;;; Code:

(defconst maduin-stamp--keys
  '(:model "Maduin-Model"
    :backend "Maduin-Backend"
    :difficulty "Maduin-Difficulty"
    :effort "Maduin-Effort"
    :agent "Maduin-Agent"
    :seat "Maduin-Seat"
    :task "Maduin-Task"
    :harness "Maduin-Harness"
    :rev "Maduin-Harness-Rev")
  "Ordered mapping from stamp plist keys to stable trailer names.")

(defun maduin-stamp--plist-p (value)
  "Return non-nil when VALUE is a proper, even-length plist."
  (condition-case nil
      (and (listp value) (zerop (% (length value) 2)))
    (error nil)))

(defun maduin-stamp--sanitize (value)
  "Return safe one-line string for VALUE, or nil when it is empty.
Strings and symbols are accepted.  Carriage returns, line feeds, and colons
become spaces so VALUE cannot forge an additional git trailer."
  (when (or (stringp value) (and value (symbolp value)))
    (let* ((text (if (symbolp value) (symbol-name value) value))
           (one-line (replace-regexp-in-string "[\r\n:]" " " text))
           (trimmed (string-trim
                     (replace-regexp-in-string "[[:space:]]+" " " one-line))))
      (unless (string-empty-p trimmed) trimmed))))

(defun maduin-stamp-trailers (plist)
  "Return ordered safe provenance trailers constructed from PLIST.
PLIST accepts :model, :backend, :difficulty, :effort, :agent, :seat, :task,
:harness, and :rev.  Each non-empty value becomes a (TRAILER . VALUE) pair.
Malformed input returns nil without signaling."
  (condition-case nil
      (when (maduin-stamp--plist-p plist)
        (let ((keys maduin-stamp--keys)
              trailers)
          (while keys
            (let* ((plist-key (pop keys))
                   (trailer-key (pop keys))
                   (value (maduin-stamp--sanitize (plist-get plist plist-key))))
              (when value
                (push (cons trailer-key value) trailers))))
          (nreverse trailers)))
    (error nil)))

(defun maduin-stamp--trailer-value (trailers key)
  "Return sanitized value for trailer KEY in TRAILERS, or nil."
  (condition-case nil
      (and (listp trailers)
           (let ((entry (assoc-string key trailers)))
             (and entry (maduin-stamp--sanitize (cdr entry)))))
    (error nil)))

(defun maduin-stamp-exec-command (trailers)
  "Return git amend command that adds TRAILERS, or nil when none are usable.
Each non-empty string (KEY . VALUE) pair becomes one shell-quoted
`--trailer' argument.  TRAILERS are already sanitized by
`maduin-stamp-trailers'; this function deliberately does not sanitize again."
  (condition-case nil
      (let ((arguments
             (delq nil
                   (mapcar
                    (lambda (trailer)
                      (let ((key (car-safe trailer))
                            (value (cdr-safe trailer)))
                        (when (and (stringp key) (not (string-empty-p key))
                                   (stringp value) (not (string-empty-p value)))
                          (concat "--trailer "
                                  (shell-quote-argument
                                   (concat key "=" value))))))
                    trailers))))
        (when arguments
          (mapconcat #'identity
                     (append '("git" "-c" "trailer.ifexists=replaceIfDifferent"
                               "commit" "--amend" "--no-edit")
                             arguments)
                     " ")))
    (error nil)))

(defun maduin-stamp-parse (message)
  "Return recognized maduin trailers found in MESSAGE in file order.
Only keys named by `maduin-stamp--keys' are returned.  Values are trimmed,
and nil or malformed MESSAGE returns nil without signaling."
  (condition-case nil
      (when (and (stringp message) (not (string-empty-p message)))
        (let ((keys maduin-stamp--keys)
              known-keys
              trailers)
          (while keys
            (pop keys)
            (push (pop keys) known-keys))
          (dolist (line (split-string message (string 10)))
            (when (string-match "^\\(Maduin-[A-Za-z-]+\\): \\(.*\\)$" line)
              (let ((key (match-string 1 line))
                    (value (string-trim (match-string 2 line))))
                (when (member key known-keys)
                  (push (cons key value) trailers)))))
          (nreverse trailers)))
    (error nil)))

(defun maduin-stamp-format (trailers)
  "Render TRAILERS as a concise one-line human provenance summary.
Model, backend, difficulty, and effort are slash-separated.  Harness and
revision follow after ` @ '.  Missing components are omitted; an empty alist
renders as \"unstamped\"."
  (let* ((summary
          (delq nil
                (mapcar (lambda (key)
                          (maduin-stamp--trailer-value trailers key))
                        '("Maduin-Model" "Maduin-Backend"
                          "Maduin-Difficulty" "Maduin-Effort"))))
         (harness (maduin-stamp--trailer-value trailers "Maduin-Harness"))
         (rev (maduin-stamp--trailer-value trailers "Maduin-Harness-Rev"))
         (source (cond
                  ((and harness rev) (format "%s (%s)" harness rev))
                  (harness harness)
                  (rev (format "(%s)" rev))))
         (model-summary (mapconcat #'identity summary "/")))
    (cond
     ((and (not (string-empty-p model-summary)) source)
      (format "%s @ %s" model-summary source))
     ((not (string-empty-p model-summary)) model-summary)
     (source source)
     (t "unstamped"))))

(provide 'maduin-stamp)

;;; maduin-stamp.el ends here
