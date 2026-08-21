;;; maduin-state.el --- snapshot store for bd-derived state  -*- lexical-binding: t; -*-

;;; Commentary:

;; A global, in-memory snapshot shared by dispatch writers and cockpit
;; readers.  This module intentionally performs no I/O.

;;; Code:

(defvar maduin-state--data nil
  "Flat plist containing snapshot values and their fetch timestamps.")

(defvar maduin-state-ttl 5.0
  "Default number of seconds a state snapshot remains fresh.")

(defvar maduin-state-invalidate-hook nil
  "Hook run with the invalidated KEY, or nil when every snapshot is reset.")

(defun maduin-state--stamp-key (key)
  "Return the timestamp plist key for symbol KEY, or nil for malformed input."
  (when (symbolp key)
    (let ((name (symbol-name key)))
      (intern (format ":%s-at"
                      (if (string-prefix-p ":" name)
                          (substring name 1)
                        name))))))

(defun maduin-state-get (key &optional default)
  "Return snapshot value for KEY, or DEFAULT when KEY is absent.
This is a pure read and distinguishes a stored nil value from a missing key."
  (if (and (symbolp key) (plist-member maduin-state--data key))
      (plist-get maduin-state--data key)
    default))

(defun maduin-state-put (key value)
  "Store VALUE for KEY and record its current float-time timestamp.
A nil VALUE is a valid, fresh snapshot value.  Malformed keys are ignored."
  (let ((stamp-key (maduin-state--stamp-key key)))
    (when stamp-key
      (setq maduin-state--data (plist-put maduin-state--data key value))
      (setq maduin-state--data
            (plist-put maduin-state--data stamp-key (float-time)))
      value)))

(defun maduin-state-fetched-at (key)
  "Return KEY's float-time timestamp, or nil when it was never fetched."
  (let ((stamp-key (maduin-state--stamp-key key)))
    (and stamp-key (plist-get maduin-state--data stamp-key))))

(defun maduin-state-stale-p (key &optional ttl now)
  "Return non-nil when KEY has no timestamp or is older than TTL.
TTL defaults to `maduin-state-ttl'; NOW defaults to the current float-time.
A snapshot exactly TTL seconds old remains fresh."
  (let ((stamp (maduin-state-fetched-at key))
        (ttl (or ttl maduin-state-ttl))
        (now (or now (float-time))))
    (or (not (numberp stamp))
        (> (- now stamp) ttl))))

(defun maduin-state--remove (property data)
  "Return DATA plist without PROPERTY and its associated value."
  (let (result)
    (while data
      (let ((key (pop data))
            (value (pop data)))
        (unless (eq key property)
          (setq result (cons value (cons key result))))))
    (nreverse result)))

(defun maduin-state-invalidate (&optional key)
  "Drop KEY and its timestamp, or reset every snapshot when KEY is nil.
Runs `maduin-state-invalidate-hook' with KEY after the reset."
  (if (null key)
      (setq maduin-state--data nil)
    (let ((stamp-key (maduin-state--stamp-key key)))
      (when stamp-key
        (setq maduin-state--data
              (maduin-state--remove
               stamp-key
               (maduin-state--remove key maduin-state--data))))))
  (run-hook-with-args 'maduin-state-invalidate-hook key))

(provide 'maduin-state)

;;; maduin-state.el ends here
