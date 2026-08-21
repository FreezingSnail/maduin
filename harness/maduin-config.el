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

(defun maduin-config--model-key (backend)
  "Return BACKEND's configured model key, or signal `user-error'."
  (pcase backend
    ('opencode 'model)
    ('kiro 'kiro-model)
    (_ (user-error "Unsupported maduin backend: %S" backend))))

(defun maduin-config--model (config backend)
  "Return CONFIG's literal model for BACKEND, or nil.
Kiro models must be explicit bare IDs: OpenCode namespace prefixes are
rejected rather than transformed."
  (let ((model (cdr (assq (maduin-config--model-key backend) config))))
    (when (and (eq backend 'kiro)
               (stringp model)
               (or (string-prefix-p "opencode/" model)
                   (string-prefix-p "opencode-go/" model)))
      (user-error "Kiro model must be a bare ID, not %S" model))
    (and (stringp model) model)))

(defun maduin-config-role-model (role backend)
  "Return ROLE's literal model configured for BACKEND, or nil.
OpenCode model strings are returned unchanged.  Kiro model IDs come only
from the explicit `kiro-model' key; no OpenCode name is transformed."
  (maduin-config--model (maduin-config--section role) backend))

(defun maduin-config-seat-model (role seat backend)
  "Return effective model for ROLE, SEAT, and BACKEND.
The named seat's backend-specific model wins over ROLE's model.  A Kiro
seat without an explicit Kiro model signals `user-error' rather than
falling back to an OpenCode model or Kiro's implicit default."
  (unless (stringp seat)
    (user-error "Maduin seat name must be a string: %S" seat))
  (let ((model (or (maduin-config--model (maduin-config--seat role seat) backend)
                   (maduin-config-role-model role backend))))
    (when (and (eq backend 'kiro)
               (or (null model) (string-empty-p model)))
      (user-error "Missing Kiro model for role %S seat %S" role seat))
    model))

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
