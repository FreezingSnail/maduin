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
