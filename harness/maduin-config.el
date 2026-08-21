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

(defconst maduin-config--option-schema
  '((harness name "harness name" string nil)
    (harness version "harness version" string nil)
    (concierge agent "concierge agent" string nil)
    (concierge backend "concierge backend" symbol (opencode kiro))
    (concierge model "concierge model" string nil)
    (concierge kiro-model "concierge Kiro model" string nil)
    (concierge kiro-fallback "concierge Kiro fallback" string nil)
    (designer agent "designer agent" string nil)
    (designer backend "designer backend" symbol (opencode kiro))
    (designer model "designer model" string nil)
    (designer kiro-model "designer Kiro model" string nil)
    (designer kiro-fallback "designer Kiro fallback" string nil)
    (fleet agent "fleet agent" string nil)
    (fleet backend "fleet backend" symbol (opencode kiro))
    (fleet model "fleet model" string nil)
    (fleet kiro-model "fleet Kiro model" string nil)
    (fleet kiro-fallback "fleet Kiro fallback" string nil)
    (fleet fallback "fleet fallback" string nil)
    (fleet poll-interval "fleet poll interval (s)" integer nil)
    (reviewer agent "reviewer agent" string nil)
    (reviewer backend "reviewer backend" symbol (opencode kiro))
    (reviewer model "reviewer model" string nil)
    (reviewer kiro-model "reviewer Kiro model" string nil)
    (reviewer kiro-fallback "reviewer Kiro fallback" string nil)
    (reviewer enabled "reviewer enabled" boolean nil)
    (reviewer esper "reviewer esper" string nil)
    (reviewer max-retries "reviewer max retries" integer nil)
    (repairer agent "repairer agent" string nil)
    (repairer backend "repairer backend" symbol (opencode kiro))
    (repairer model "repairer model" string nil)
    (repairer kiro-model "repairer Kiro model" string nil)
    (repairer kiro-fallback "repairer Kiro fallback" string nil)
    (repairer enabled "repairer enabled" boolean nil)
    (repairer esper "repairer esper" string nil)
    (repairer max-retries "repairer max retries" integer nil)
    (welfare handoff-timeout "welfare handoff timeout (s)" integer nil)
    (workspaces path "workspace path" string nil)
    (workspaces land-on-stop "land workspaces on stop" boolean nil))
  "Editable scalar options of `maduin-config'.")

(defun maduin-config--option-spec (section key)
  "Return schema row for SECTION and KEY, or nil when absent."
  (cl-find-if (lambda (spec)
                (and (eq (nth 0 spec) section)
                     (eq (nth 1 spec) key)))
              maduin-config--option-schema))

(defun maduin-config-option (section key)
  "Return current value for schema option SECTION and KEY, or nil."
  (when (maduin-config--option-spec section key)
    (let ((section-cell (assq section maduin-config)))
      (and section-cell
           (cdr (assq key (cdr section-cell)))))))

(defun maduin-config-options ()
  "Return plists describing every editable `maduin-config' option."
  (mapcar (lambda (spec)
            (let ((section (nth 0 spec))
                  (key (nth 1 spec)))
              (list :section section :key key
                    :label (nth 2 spec) :type (nth 3 spec)
                    :choices (nth 4 spec)
                    :value (maduin-config-option section key))))
          maduin-config--option-schema))

(defun maduin-config-set-option (section key value)
  "Set schema option SECTION and KEY to VALUE, returning VALUE.
Signal `user-error' without mutation when the option or VALUE is invalid."
  (let ((spec (maduin-config--option-spec section key)))
    (unless spec
      (user-error "Unknown maduin config option: %S/%S" section key))
    (let ((valid (pcase (nth 3 spec)
                   ('integer (integerp value))
                   ('string (stringp value))
                   ('symbol (and (symbolp value)
                                 (memq value (nth 4 spec))))
                   ('boolean (memq value '(t nil))))))
      (unless valid
        (user-error "Invalid value for %S/%S: %S" section key value)))
    (let ((section-cell (assq section maduin-config)))
      (unless section-cell
        (user-error "Missing maduin config section: %S" section))
      (let ((key-cell (assq key (cdr section-cell))))
        (if key-cell
            (setcdr key-cell value)
          (setcdr section-cell
                  (nconc (cdr section-cell) (list (cons key value)))))))
    value))

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
