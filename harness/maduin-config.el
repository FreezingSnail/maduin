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

(defconst maduin-config--difficulty-tiers '(low high)
  "Difficulty tiers with dedicated Kiro model configuration keys.")

(defun maduin-config--tier-model-key (tier)
  "Return Kiro model configuration key for difficulty TIER, or nil."
  (pcase tier
    ('low 'kiro-model-low)
    ('high 'kiro-model-high)
    (_ nil)))

(defconst maduin-config--effort-allowlists
  '((kiro . ("low" "medium" "high" "xhigh" "max"))
    (opencode . ("minimal" "low" "medium" "high" "max")))
  "Allowed reasoning-effort spellings by backend.")

(defun maduin-config--tier-effort-key (backend tier)
  "Return BACKEND's effort configuration key for difficulty TIER, or nil."
  (pcase (list backend tier)
    (`(opencode low) 'effort-low)
    (`(opencode high) 'effort-high)
    (`(kiro low) 'kiro-effort-low)
    (`(kiro high) 'kiro-effort-high)
    (_ nil)))

(defun maduin-config--effort-valid-p (backend effort)
  "Return non-nil when EFFORT is a safe allowed value for BACKEND."
  (and (stringp effort)
       (not (string-empty-p effort))
       (not (string-match-p "[[:space:]/]" effort))
       (member (downcase effort)
               (cdr (assq backend maduin-config--effort-allowlists)))))

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

(defun maduin-config-crew-backend ()
  "Return the explicit crew-wide backend override, or nil when unset.
Malformed values act as unset so a hand-edited config retains the existing
per-seat, per-role, and OpenCode-default resolution semantics."
  (let* ((crew (cdr (assq 'crew maduin-config)))
         (backend (and (listp crew) (cdr (assq 'backend crew)))))
    (and (maduin-config--valid-backend-p backend) backend)))

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
An explicit crew override wins; otherwise a valid named-seat backend wins,
then ROLE's backend, which itself defaults to `opencode'."
  (unless (stringp seat)
    (user-error "Maduin seat name must be a string: %S" seat))
  (or (maduin-config-crew-backend)
      (let* ((entry (maduin-config--seat role seat))
             (backend (and entry (cdr (assq 'backend entry)))))
        (if (maduin-config--valid-backend-p backend)
            backend
          (maduin-config-role-backend role)))))

(defun maduin-config--model-key (backend)
  "Return BACKEND's configured model key, or signal `user-error'."
  (pcase backend
    ('opencode 'model)
    ('kiro 'kiro-model)
    (_ (user-error "Unsupported maduin backend: %S" backend))))

(defun maduin-config--model-style (model backend)
  "Return literal MODEL for BACKEND, or nil when MODEL is not a string.
Kiro models must be explicit bare IDs: OpenCode namespace prefixes are
rejected rather than transformed."
  (when (and (eq backend 'kiro)
             (stringp model)
             (or (string-prefix-p "opencode/" model)
                 (string-prefix-p "opencode-go/" model)))
    (user-error "Kiro model must be a bare ID, not %S" model))
  (and (stringp model) model))

(defun maduin-config--model (config backend)
  "Return CONFIG's literal model for BACKEND, or nil."
  (maduin-config--model-style
   (cdr (assq (maduin-config--model-key backend) config)) backend))

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

(defun maduin-config-difficulty-model (role seat backend difficulty)
  "Return effective model for ROLE, SEAT, BACKEND, and DIFFICULTY.
Kiro tier models prefer named-seat values, then role values.  Unknown and
unset difficulty values use `maduin-config-seat-model'.  OpenCode always
uses `maduin-config-seat-model' unchanged."
  (unless (stringp seat)
    (user-error "Maduin seat name must be a string: %S" seat))
  ;; Preserve `maduin-config--model-key' validation for unsupported backends.
  (maduin-config--model-key backend)
  (let ((tier-key (and (memq difficulty maduin-config--difficulty-tiers)
                       (maduin-config--tier-model-key difficulty))))
    (if (and (eq backend 'kiro) tier-key)
        (or (let ((model (maduin-config--model-style
                          (cdr (assq tier-key (maduin-config--seat role seat)))
                          backend)))
              (and model (not (string-empty-p model)) model))
            (let ((model (maduin-config--model-style
                          (cdr (assq tier-key (maduin-config--section role)))
                          backend)))
              (and model (not (string-empty-p model)) model))
            (maduin-config-seat-model role seat backend))
      (maduin-config-seat-model role seat backend))))

(defun maduin-config-difficulty-effort (role seat backend difficulty)
  "Return effective effort for ROLE, SEAT, BACKEND, and DIFFICULTY, or nil.
Named-seat values override role values.  Invalid effort values are logged and
omitted so they cannot make a spawned command line unsafe or invalid."
  (unless (stringp seat)
    (user-error "Maduin seat name must be a string: %S" seat))
  (let ((tier-key (and (memq difficulty maduin-config--difficulty-tiers)
                       (maduin-config--tier-effort-key backend difficulty))))
    (when tier-key
      (let ((effort
             (condition-case nil
                 (or (cdr (assq tier-key (maduin-config--seat role seat)))
                     (cdr (assq tier-key (maduin-config--section role))))
               (error nil))))
        (cond
         ((null effort) nil)
         ((maduin-config--effort-valid-p backend effort) (downcase effort))
         (t
          (message "maduin-config: ignoring invalid %S effort %S" backend effort)
          nil))))))

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
  (when (fboundp 'maduin-pipeline-config-bump)
    (maduin-pipeline-config-bump))
  backend)

(defconst maduin-config--option-schema
  '((harness name "harness name" string nil)
    (harness version "harness version" string nil)
    (crew backend "crew-wide backend provider override" backend (opencode kiro))
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
    (fleet kiro-model-low "fleet Kiro model (low difficulty)" string nil)
    (fleet kiro-model-high "fleet Kiro model (high difficulty)" string nil)
    (fleet kiro-effort-low "fleet Kiro effort (low difficulty)" string nil)
    (fleet kiro-effort-high "fleet Kiro effort (high difficulty)" string nil)
    (fleet effort-low "fleet OpenCode variant (low difficulty)" string nil)
    (fleet effort-high "fleet OpenCode variant (high difficulty)" string nil)
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
Signal `user-error' without mutation when the option or VALUE is invalid.
String options accept only strings, so the cockpit cannot clear an effort
option back to nil; unset effort values by editing config.el."
  (let ((spec (maduin-config--option-spec section key)))
    (unless spec
      (user-error "Unknown maduin config option: %S/%S" section key))
    (let ((valid (pcase (nth 3 spec)
                   ('integer (integerp value))
                   ('string (stringp value))
                   ('symbol (and (symbolp value)
                                 (memq value (nth 4 spec))))
                   ('backend (or (null value)
                                 (maduin-config--valid-backend-p value)))
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
    (when (fboundp 'maduin-pipeline-config-bump)
      (maduin-pipeline-config-bump))
    value))

(defun maduin-config-set-crew-backend (backend)
  "Set crew-wide BACKEND override, or nil to unset it, and return BACKEND."
  (maduin-config-set-option 'crew 'backend backend))

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
