;;; maduin-cockpit-face.el --- theme-adaptive cockpit faces -*- lexical-binding: t; -*-

;; Single source of truth for cockpit faces: status pills and pipeline
;; chips.  Detects dark vs light themes from the `default' face
;; background, applies the matching palette via `face-spec-set', and
;; re-applies on `after-load-theme-hook' (idle-scheduled).  Mirrors
;; chaplet-face.el.  Safe in batch (no display required).

;;; Code:

(require 'color)

(defgroup maduin-cockpit nil
  "Maduin cockpit dashboard faces."
  :group 'tools)

;;; Faces

;; Status faces (defface defaults = dark palette; adapted at runtime).

(defface maduin-cockpit-state-dead
  '((t :foreground "#5c6370" :background "#2b2f36" :box t))
  "Face for dead (no live process) seats."
  :group 'maduin-cockpit)

(defface maduin-cockpit-state-idle
  '((t :foreground "#61afef" :background "#1f3b5c" :box t))
  "Face for idle seats."
  :group 'maduin-cockpit)

(defface maduin-cockpit-state-working
  '((t :foreground "#98c379" :background "#1e3a25" :box t))
  "Face for working (dispatch) seats."
  :group 'maduin-cockpit)

(defface maduin-cockpit-state-running
  '((t :foreground "#56b6c2" :background "#18373a" :box t))
  "Face for running (live session) seats."
  :group 'maduin-cockpit)

(defface maduin-cockpit-state-repairing
  '((t :foreground "#e06c75" :background "#4a2226" :box t))
  "Face for repairing seats."
  :group 'maduin-cockpit)

;; Pipeline chip faces.

(defface maduin-cockpit-chip-queued
  '((t :foreground "#5c6370" :background "#2b2f36" :box t))
  "Face for queued pipeline chips."
  :group 'maduin-cockpit)

(defface maduin-cockpit-chip-active
  '((t :foreground "#61afef" :background "#1f3b5c" :box t))
  "Face for active pipeline chips."
  :group 'maduin-cockpit)

(defface maduin-cockpit-chip-completed
  '((t :foreground "#98c379" :background "#1e3a25" :box t))
  "Face for completed pipeline chips."
  :group 'maduin-cockpit)

(defface maduin-cockpit-chip-blocked
  '((t :foreground "#e06c75" :background "#4a2226" :box t))
  "Face for blocked pipeline chips."
  :group 'maduin-cockpit)

(defface maduin-cockpit-chip-fleet-free
  '((t :foreground "#98c379" :background "#1e3a25" :box t))
  "Face for fleet-free pipeline chips."
  :group 'maduin-cockpit)

(defface maduin-cockpit-chip-fleet-busy
  '((t :foreground "#c678dd" :background "#3a2a44" :box t))
  "Face for fleet-busy pipeline chips."
  :group 'maduin-cockpit)

;;; Palettes

(defconst maduin-cockpit-face--palette
  '((dark
     (maduin-cockpit-state-dead     . "#5c6370")
     (maduin-cockpit-state-idle     . "#61afef")
     (maduin-cockpit-state-working  . "#98c379")
     (maduin-cockpit-state-running  . "#56b6c2")
     (maduin-cockpit-state-repairing . "#e06c75")
     (maduin-cockpit-chip-queued    . "#5c6370")
     (maduin-cockpit-chip-active    . "#61afef")
     (maduin-cockpit-chip-completed . "#98c379")
     (maduin-cockpit-chip-blocked   . "#e06c75")
     (maduin-cockpit-chip-fleet-free . "#98c379")
     (maduin-cockpit-chip-fleet-busy . "#c678dd"))
    (light
     (maduin-cockpit-state-dead     . "#6e7278")
     (maduin-cockpit-state-idle     . "#1f6fb2")
     (maduin-cockpit-state-working  . "#1f7a3d")
     (maduin-cockpit-state-running  . "#007c84")
     (maduin-cockpit-state-repairing . "#b3261e")
     (maduin-cockpit-chip-queued    . "#6e7278")
     (maduin-cockpit-chip-active    . "#1f6fb2")
     (maduin-cockpit-chip-completed . "#1f7a3d")
     (maduin-cockpit-chip-blocked   . "#b3261e")
     (maduin-cockpit-chip-fleet-free . "#1f7a3d")
     (maduin-cockpit-chip-fleet-busy . "#7b2d8b")))
  "Palettes keyed by theme: ((dark (face . color) ...) (light ...)).")

(defconst maduin-cockpit-face--pill-faces
  '(maduin-cockpit-state-dead maduin-cockpit-state-idle
    maduin-cockpit-state-working maduin-cockpit-state-running
    maduin-cockpit-state-repairing
    maduin-cockpit-chip-queued maduin-cockpit-chip-active
    maduin-cockpit-chip-completed maduin-cockpit-chip-blocked
    maduin-cockpit-chip-fleet-free maduin-cockpit-chip-fleet-busy)
  "Faces rendered as pills (dim background + box).")

;;; Theme detection

(defun maduin-cockpit-face--luminance (color)
  "Return the relative luminance (0..1) of COLOR string.
Returns 1.0 when COLOR cannot be parsed."
  (condition-case nil
      (let ((rgb (color-name-to-rgb color)))
        (+ (* 0.2126 (nth 0 rgb))
           (* 0.7152 (nth 1 rgb))
           (* 0.0722 (nth 2 rgb))))
    (error 1.0)))

(defun maduin-cockpit-face-dark-p ()
  "Return non-nil when the `default' face background is dark.
A nil or unspecified background counts as light."
  (let ((bg (face-attribute 'default :background nil 'default)))
    (and (stringp bg)
         (not (string= bg "unspecified-bg"))
         (< (maduin-cockpit-face--luminance bg) 0.5))))

(defun maduin-cockpit-face--dim-background (color)
  "Return a dim background color derived from COLOR.
Mixes COLOR (18%) into the `default' face background for a subtle pill."
  (let ((bg (face-attribute 'default :background nil 'default)))
    (setq bg (if (and (stringp bg) (not (string= bg "unspecified-bg")))
                 bg
               "#282c34"))
    (if (fboundp 'color-mix)
        (color-mix 'srgb color bg 0.18)
      bg)))

;;; Adaptation

(defvar maduin-cockpit-face--idle-timer nil
  "Pending idle timer for `maduin-cockpit-face-adapt'.")

(defun maduin-cockpit-face-adapt ()
  "Re-spec every cockpit face from the active dark/light palette.
Idempotent, batch-safe, and never signals: failures are logged and
ignored (chaplet-face pattern).  Only calls `face-spec-set'."
  (condition-case err
      (let ((mode (if (maduin-cockpit-face-dark-p) 'dark 'light))
            (palette (cdr (assq (if (maduin-cockpit-face-dark-p) 'dark 'light)
                                maduin-cockpit-face--palette))))
        (dolist (entry palette)
          (let ((face (car entry))
                (color (cdr entry)))
            (face-spec-set
             face
             (if (memq face maduin-cockpit-face--pill-faces)
                 `((t :foreground ,color
                      :background ,(maduin-cockpit-face--dim-background color)
                      :box t))
               `((t :foreground ,color)))
             'face-defface-spec)))
        (message "maduin-cockpit-face: adapted palette (%s)" mode))
    (error (message "maduin-cockpit-face: adapt failed: %s"
                    (error-message-string err)))))

(defun maduin-cockpit-face-adapt-idle ()
  "Schedule `maduin-cockpit-face-adapt' on an idle timer.
Replaces any previously scheduled run; never errors."
  (when maduin-cockpit-face--idle-timer
    (cancel-timer maduin-cockpit-face--idle-timer))
  (setq maduin-cockpit-face--idle-timer
        (run-with-idle-timer 0.5 nil #'maduin-cockpit-face-adapt)))

(defun maduin-cockpit-face-setup ()
  "Apply the active palette and adapt on future theme changes.
Idempotent: `after-load-theme-hook' is registered at most once."
  (maduin-cockpit-face-adapt)
  (add-hook 'after-load-theme-hook #'maduin-cockpit-face-adapt-idle))

;;; Mappings

(defun maduin-cockpit-state-face (status)
  "Return the state face symbol for STATUS symbol, or nil for unknown."
  (pcase status
    ('dead      'maduin-cockpit-state-dead)
    ('idle      'maduin-cockpit-state-idle)
    ('working   'maduin-cockpit-state-working)
    ('running   'maduin-cockpit-state-running)
    ('repairing 'maduin-cockpit-state-repairing)
    (_ nil)))

(defun maduin-cockpit-state-color (status)
  "Return the effective foreground color string of STATUS's face.
Falls back to the dark palette color when the face has no usable
foreground (e.g. face unset in batch).  Nil for unknown STATUS."
  (let ((face (maduin-cockpit-state-face status)))
    (if (null face)
        nil
      (let ((fg (condition-case nil
                    (face-attribute face :foreground nil 'default)
                  (error nil))))
        (cond ((and (stringp fg) (not (string= fg "unspecified-fg"))) fg)
              (t (cdr (assq face (cdr (assq 'dark
                                            maduin-cockpit-face--palette))))))))))

(defun maduin-cockpit-chip-face (stat-key)
  "Return the pipeline chip face symbol for STAT-KEY symbol, or nil."
  (pcase stat-key
    ('queued     'maduin-cockpit-chip-queued)
    ('active     'maduin-cockpit-chip-active)
    ('completed  'maduin-cockpit-chip-completed)
    ('blocked    'maduin-cockpit-chip-blocked)
    ('fleet-free 'maduin-cockpit-chip-fleet-free)
    ('fleet-busy 'maduin-cockpit-chip-fleet-busy)
    (_ nil)))

;; Apply defaults once at load; re-adapt on theme changes thereafter.
(maduin-cockpit-face-setup)

(provide 'maduin-cockpit-face)
;;; maduin-cockpit-face.el ends here
