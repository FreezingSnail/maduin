;;; maduin-config.el --- configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'cl-lib)
(require 'project)

;; Real config lives in harness/config.el (single source of truth).
;; Load it so (require 'maduin-config) resolves the value.
(defconst maduin-config--file
  (expand-file-name "config.el" (file-name-directory load-file-name))
  "Native Elisp config source.  It is intentionally never rewritten here.")

(load-file maduin-config--file)

(defconst maduin-config--role-sections
  '((implementer . fleet)
    (designer . designer)
    (concierge . concierge)
    (repairer . repairer)
    (reviewer . reviewer))
  "Mapping from runtime roles to top-level config sections.")

(defconst maduin-config--supported-backends '(opencode kiro)
  "Backend symbols accepted by the runtime configuration API.")

(defun maduin-config--section-for-role (role)
  "Return config section for supported ROLE, or signal `user-error'."
  (let ((section (cdr (assq role maduin-config--role-sections))))
    (unless section
      (user-error "Unsupported maduin role: %S" role))
    section))

(defun maduin-config--section (role)
  "Return configured section for ROLE, or signal `user-error'."
  (let* ((section-name (maduin-config--section-for-role role))
         (section (cdr (assq section-name maduin-config))))
    (unless (listp section)
      (user-error "Missing maduin config section: %S" section-name))
    section))

(defun maduin-config--valid-backend-p (backend)
  "Return non-nil when BACKEND is a supported backend symbol."
  (memq backend maduin-config--supported-backends))

(defun maduin-config-role-backend (role)
  "Return ROLE's valid backend, defaulting to `opencode'.
ROLE maps through `maduin-config--role-sections'.  Missing or malformed
backend values deliberately inherit the stable `opencode' default."
  (let ((backend (cdr (assq 'backend (maduin-config--section role)))))
    (if (maduin-config--valid-backend-p backend) backend 'opencode)))

(defun maduin-config--seat (role seat)
  "Return ROLE's configured SEAT alist, or nil when no name matches."
  (let ((seats (cdr (assq 'seats (maduin-config--section role)))))
    (and (listp seats)
         (cl-find-if (lambda (entry)
                       (and (listp entry)
                            (equal (cdr (assq 'name entry)) seat)))
                     seats))))

(defun maduin-config-seat-backend (role seat)
  "Return effective backend for ROLE and SEAT.
A valid `(backend . SYMBOL)' on the named seat wins; otherwise return
ROLE's backend, which itself defaults to `opencode'."
  (unless (stringp seat)
    (user-error "Maduin seat name must be a string: %S" seat))
  (let* ((entry (maduin-config--seat role seat))
         (backend (and entry (cdr (assq 'backend entry)))))
    (if (maduin-config--valid-backend-p backend)
        backend
      (maduin-config-role-backend role))))

(defun maduin-config-set-seat-backend (role seat backend)
  "Set existing ROLE/SEAT's runtime BACKEND and return BACKEND.
ROLE, SEAT, and BACKEND are fully validated before mutation.  BACKEND
must be `opencode' or `kiro'.  This changes only the named seat alist;
call `maduin-config-save' explicitly to request persistence."
  (maduin-config--section-for-role role)
  (unless (stringp seat)
    (user-error "Maduin seat name must be a string: %S" seat))
  (unless (maduin-config--valid-backend-p backend)
    (user-error "Unsupported maduin backend: %S" backend))
  (let ((entry (maduin-config--seat role seat)))
    (unless entry
      (user-error "Unknown maduin seat %S for role %S" seat role))
    (let ((cell (assq 'backend entry)))
      (if cell
          (setcdr cell backend)
        (nconc entry (list (cons 'backend backend))))))
  backend)

(defun maduin-config-save ()
  "Refuse to rewrite executable `config.el'.
Calling this function is an explicit persistence request, never an
implicit side effect of runtime backend changes.  Native config.el may
contain arbitrary executable Elisp, so generic serialization cannot
prove lossless; this function signals `user-error' without changing
that file or `maduin-config'."
  (user-error "Maduin config save refused: cannot losslessly rewrite executable Elisp"))

(defun maduin-project-root ()
  "Return the root directory of the current project, as a string.
Use `project-root' of `project-current'; fall back to
`default-directory' when not inside a project."
  (let ((proj (project-current)))
    (if proj
        (project-root proj)
      default-directory)))

(provide 'maduin-config)

;;; maduin-config.el ends here
