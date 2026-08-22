;;; maduin-test.el --- ERT tests for all harness components  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT 測試覆蓋 harness 各組件：config、bd-bridge、session、
;; handoff、pipeline、cockpit、main。全部標記
;; :tags '(maduin)。bd 實測以 condition-case 守護，
;; 環境無 bd 時測試仍通過。

;;; Code:

(require 'ert)
(require 'cl-lib)

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))

(defconst maduin-test--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing maduin-test.el (the harness dir).")

(defun maduin-test--fake-opencode-shim ()
  "Return path to the repo fake opencode shim, or nil when missing."
  (let ((p (expand-file-name "test/fake-opencode" maduin-test--dir)))
    (and (file-exists-p p) p)))

(require 'maduin)
(require 'maduin-state)
(require 'maduin-bd-bridge)
(require 'maduin-session)
(require 'maduin-handoff)
(require 'maduin-pipeline)
(require 'maduin-cockpit)
(require 'maduin-review)
(require 'maduin-terminal)
(require 'maduin-dispatch)
(require 'maduin-designer)
(require 'maduin-concierge)
(require 'maduin-backend)

;; Pre-dispatch seat sync runs real git against real seat worktrees.  Neutralise
;; it for the whole suite: a test that spawns must never rebase or reset a live
;; seat branch.  Tests that exercise the sync itself let-bind this seam (or call
;; `maduin-workspace-sync' with mocked git seams) and so shadow this default;
;; `maduin-test-dispatch-sync-seam-default' guards the production wiring.
(defconst maduin-test--dispatch-sync-default maduin-dispatch--sync-fn
  "Shipped value of `maduin-dispatch--sync-fn' before the suite neutralises it.")

(setq maduin-dispatch--sync-fn (lambda (_seat) 'synced))

;;; Helpers

(defun maduin-test--temp-dir ()
  "Return a new temporary directory path."
  (make-temp-file "sh-test-" t))

(defun maduin-test--bd-forget-matching (substr)
  "Forget all bd memories whose key contains SUBSTR.  Never errors."
  (condition-case nil
      (let* ((out (with-temp-buffer
                    (call-process shell-file-name nil t nil
                                  shell-command-switch "bd memories --json")
                    (buffer-string)))
             (data (and (stringp out)
                        (json-read-from-string out))))
        (when (hash-table-p data)
          (maphash (lambda (key _val)
                     (when (string-match-p substr key)
                       (call-process shell-file-name nil nil nil
                                     shell-command-switch
                                     (format "bd forget %s -q" key))))
                   data)))
    (error nil)))

(defmacro maduin-test--no-io (&rest body)
  "Run BODY with every synchronous subprocess entry point stubbed to signal.
`cl-letf' restores every original definition even when BODY signals."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'call-process)
              (lambda (&rest _args) (error "maduin test: synchronous I/O forbidden")))
             ((symbol-function 'call-process-shell-command)
              (lambda (&rest _args) (error "maduin test: synchronous I/O forbidden")))
             ((symbol-function 'call-process-region)
              (lambda (&rest _args) (error "maduin test: synchronous I/O forbidden")))
             ((symbol-function 'make-process)
              (lambda (&rest _args) (error "maduin test: synchronous I/O forbidden")))
             ((symbol-function 'start-process)
              (lambda (&rest _args) (error "maduin test: synchronous I/O forbidden")))
             ((symbol-function 'shell-command-to-string)
              (lambda (&rest _args) (error "maduin test: synchronous I/O forbidden"))))
     ,@body))

(ert-deftest maduin-test-cockpit-render-path-io-free ()
  :tags '(maduin)
  (let ((buf (generate-new-buffer " *maduin-cockpit-io-free*"))
        (maduin-state--data nil)
        (maduin-dispatch--active
         (list (list :handle "perf-session" :seat "ifrit" :role 'implementer
                     :task "maduin-perf" :model "flash" :backend 'opencode
                     :started 0.0 :status 'working :phase "coding"))))
    (unwind-protect
        (let ((titles (make-hash-table :test #'equal)))
          (puthash "maduin-perf" (cons "Cached render title" 0.0) titles)
          (maduin-state-put 'titles titles)
          (maduin-state-put 'pipeline
                             '(:queued 2 :active 1 :completed 3 :blocked 1
                               :fleet-free 2 :fleet-busy 1))
          (with-current-buffer buf
            (tabulated-list-mode)
            (maduin-test--no-io
              (maduin-cockpit-refresh)
              (maduin-cockpit-refresh)
              (should (= (length (maduin-cockpit--rows)) 7)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest maduin-test-dispatch-tick-io-free ()
  :tags '(maduin)
  (let ((maduin-dispatch--active nil)
        (maduin-dispatch--draining nil)
        (maduin-dispatch--tick-in-flight nil)
        (maduin-dispatch--tick-notify-pending nil)
        (maduin-dispatch--drift-fix-async-fn
         (lambda (callback) (funcall callback nil t) (quote drift-fix)))
        (maduin-dispatch--in-progress-async-fn
         (lambda (callback) (funcall callback nil t) 'in-progress))
        (maduin-dispatch--ready-async-fn
         (lambda (callback) (funcall callback nil t) 'ready))
        (maduin-dispatch--open-epics-async-fn
         (lambda (callback) (funcall callback nil t) 'open-epics)))
    (maduin-test--no-io
      (maduin-dispatch-run-loop)
      (should-not maduin-dispatch--tick-in-flight))))

(ert-deftest maduin-test-cockpit-refresh-budget ()
  :tags '(maduin)
  ;; Coarse local-CI guard: snapshot-only rendering must stay comfortably fast.
  (let ((buf (generate-new-buffer " *maduin-cockpit-refresh-budget*"))
        (maduin-state--data nil)
        (maduin-dispatch--active nil)
        (iterations 20))
    (unwind-protect
        (progn
          (maduin-state-put 'pipeline
                             '(:queued 3 :active 1 :completed 8 :blocked 2
                               :fleet-free 2 :fleet-busy 1))
          (with-current-buffer buf
            (tabulated-list-mode)
            (let ((started (float-time)))
              (dotimes (_ iterations) (maduin-cockpit-refresh))
              (should (< (/ (- (float-time) started) iterations) 0.008)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest maduin-test-cockpit-notify-storm-budget ()
  :tags '(maduin)
  (let* ((buf (generate-new-buffer " *maduin-cockpit-notify-storm*"))
         (maduin-cockpit-buffer-name (buffer-name buf))
         (clock 0.0)
         (started clock)
         (renders 0)
         (scheduled nil)
         (maduin-cockpit--pending-render nil)
         (maduin-cockpit--last-render nil)
         (maduin-cockpit--now-fn (lambda () clock)))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (buffer &optional _all)
                     (and (eq buffer buf) (selected-window))))
                  ((symbol-function 'timerp) (lambda (timer) (eq timer 'render-timer)))
                  ((symbol-function 'run-at-time)
                   (lambda (_delay _repeat function &rest args)
                     (setq scheduled (list function args)) 'render-timer))
                  ((symbol-function 'maduin-pipeline-status-refresh) #'ignore)
                  ((symbol-function 'maduin-cockpit-refresh)
                   (lambda ()
                     (cl-incf renders)
                     (setq maduin-cockpit--last-render
                           (funcall maduin-cockpit--now-fn)))))
          (dotimes (interval 4)
            (setq clock (* interval maduin-cockpit-min-render-interval))
            (dotimes (_ 50) (maduin-cockpit--schedule-refresh))
            (apply (car scheduled) (cadr scheduled)))
          (let ((elapsed (- clock started)))
            (should (<= renders
                        (+ 1.0 (/ elapsed maduin-cockpit-min-render-interval))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;; 1. config

(ert-deftest maduin-test-config-loads ()
  :tags '(maduin)
  (should maduin-config))

(ert-deftest maduin-test-config-concierge-seats ()
  :tags '(maduin)
  (let ((concierge (cdr (assq 'seats (cdr (assq 'concierge maduin-config))))))
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) concierge)
                   '("alexander")))
    (should (eq (alist-get 'role (car concierge)) 'concierge))))

(ert-deftest maduin-test-config-designer-seats ()
  :tags '(maduin)
  (let ((designer (cdr (assq 'seats (cdr (assq 'designer maduin-config))))))
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) designer)
                   '("ramuh")))
    (should (eq (alist-get 'role (car designer)) 'designer))))

(ert-deftest maduin-test-config-fleet-seats ()
  :tags '(maduin)
  (let ((fleet (cdr (assq 'seats (cdr (assq 'fleet maduin-config))))))
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) fleet)
                   '("ifrit" "shiva" "titan")))
    (should (equal (mapcar (lambda (s) (alist-get 'role s)) fleet)
                   '(implementer implementer implementer)))))

(ert-deftest maduin-test-config-seats ()
  :tags '(maduin)
  (should (equal (maduin--seats)
                 '(("alexander" . "concierge")
                   ("ramuh" . "designer")
                   ("ifrit" . "implementer")
                   ("shiva" . "implementer")
                   ("titan" . "implementer")))))

(ert-deftest maduin-test-config-seat-models ()
  :tags '(maduin)
  (should (equal (maduin--seat-model "alexander") "opencode-go/deepseek-v4-pro"))
  (should (equal (maduin--seat-model "ramuh") "opencode-go/deepseek-v4-pro"))
  (should (equal (maduin--seat-model "ifrit") "opencode/deepseek-v4-flash-free"))
  (should (equal (maduin--seat-model "shiva") "opencode/deepseek-v4-flash-free"))
  (should (equal (maduin--seat-model "titan") "opencode/deepseek-v4-flash-free")))

(ert-deftest maduin-test-config-fleet-fallback ()
  :tags '(maduin)
  (should (equal (maduin-dispatch--seat-fallback 'implementer)
                 "opencode-go/deepseek-v4-flash"))
  (should-not (maduin-dispatch--seat-fallback 'designer)))

(ert-deftest maduin-test-config-fleet-tier-model-keys ()
  :tags '(maduin)
  (should (equal (maduin-config-option 'fleet 'kiro-model-low)
                 "gpt-5.6-luna"))
  (should (equal (maduin-config-option 'fleet 'kiro-model-high)
                 "gpt-5.6-terra"))
  (should (equal (maduin-config-role-model 'implementer 'kiro)
                 "gpt-5.6-terra"))
  (should (equal (maduin-config-role-model 'implementer 'opencode)
                 "opencode/deepseek-v4-flash-free")))


(ert-deftest maduin-test-config-difficulty-model-kiro-tiers ()
  :tags '(maduin)
  (should (equal (maduin-config-difficulty-model 'implementer "ifrit" 'kiro 'low)
                 "gpt-5.6-luna"))
  (should (equal (maduin-config-difficulty-model 'implementer "ifrit" 'kiro 'high)
                 "gpt-5.6-terra"))
  (should (equal (maduin-config-difficulty-model 'implementer "ifrit" 'kiro nil)
                 (maduin-config-seat-model 'implementer "ifrit" 'kiro)))
  (let ((maduin-config (copy-tree maduin-config)))
    (let ((fleet (cdr (assq 'fleet maduin-config))))
      (setcdr fleet (assq-delete-all 'kiro-model-low (cdr fleet)))
      (setcdr fleet (assq-delete-all 'kiro-model-high (cdr fleet))))
    (should (equal (maduin-config-difficulty-model 'implementer "ifrit" 'kiro 'low)
                   (maduin-config-seat-model 'implementer "ifrit" 'kiro))))
  (let ((maduin-config (copy-tree maduin-config)))
    (setcdr (assq 'kiro-model-low (cdr (assq 'fleet maduin-config))) "")
    (should (equal (maduin-config-difficulty-model 'implementer "ifrit" 'kiro 'low)
                   (maduin-config-seat-model 'implementer "ifrit" 'kiro)))))

(ert-deftest maduin-test-config-difficulty-model-seat-override ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (let* ((fleet (cdr (assq 'fleet maduin-config)))
           (seats (cdr (assq 'seats fleet)))
           (seat (cl-find-if (lambda (entry)
                               (equal (alist-get 'name entry) "ifrit"))
                             seats)))
      (setcdr seat (append (cdr seat) '((kiro-model-low . "gpt-5.6-luna")))))
    (should (equal (maduin-config-difficulty-model 'implementer "ifrit" 'kiro 'low)
                   "gpt-5.6-luna"))))

(ert-deftest maduin-test-config-difficulty-model-opencode-ignores-tier ()
  :tags '(maduin)
  (dolist (tier '(low high))
    (should (equal (maduin-config-difficulty-model 'implementer "ifrit" 'opencode tier)
                   "opencode/deepseek-v4-flash-free"))))

(ert-deftest maduin-test-config-difficulty-model-unknown-tier-defaults ()
  :tags '(maduin)
  (should (equal (maduin-config-difficulty-model 'implementer "ifrit" 'kiro 'medium)
                 (maduin-config-seat-model 'implementer "ifrit" 'kiro))))

(ert-deftest maduin-test-config-difficulty-model-rejects-prefixed-kiro ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (setcdr (assq 'kiro-model-low (cdr (assq 'fleet maduin-config)))
            "opencode/foo")
    (should-error (maduin-config-difficulty-model 'implementer "ifrit" 'kiro 'low)
                  :type 'user-error)))
(ert-deftest maduin-test-config-difficulty-effort-kiro-tiers ()
  :tags '(maduin)
  (should (equal (maduin-config-difficulty-effort 'implementer "ifrit" 'kiro 'low)
                 "medium"))
  (should (equal (maduin-config-difficulty-effort 'implementer "ifrit" 'kiro 'high)
                 "high"))
  (let ((maduin-config (copy-tree maduin-config)))
    (setcdr (assq 'kiro-effort-high (cdr (assq 'fleet maduin-config))) "High")
    (should (equal (maduin-config-difficulty-effort 'implementer "ifrit" 'kiro 'high)
                   "high")))
  (let ((maduin-config (copy-tree maduin-config)))
    (setcdr (assq 'kiro-effort-low (cdr (assq 'fleet maduin-config))) "xhigh")
    (should (equal (maduin-config-difficulty-effort 'implementer "ifrit" 'kiro 'low)
                   "xhigh"))))

(ert-deftest maduin-test-config-difficulty-effort-opencode-unset ()
  :tags '(maduin)
  (dolist (tier '(low high))
    (should-not (maduin-config-difficulty-effort 'implementer "ifrit" 'opencode tier))))

(ert-deftest maduin-test-config-difficulty-effort-seat-override ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (let* ((fleet (cdr (assq 'fleet maduin-config)))
           (seats (cdr (assq 'seats fleet)))
           (seat (cl-find-if (lambda (entry)
                               (equal (alist-get 'name entry) "ifrit"))
                             seats)))
      (setcdr seat (append (cdr seat) '((kiro-effort-low . "low")))))
    (should (equal (maduin-config-difficulty-effort 'implementer "ifrit" 'kiro 'low)
                   "low"))))

(ert-deftest maduin-test-config-difficulty-effort-rejects-invalid ()
  :tags '(maduin)
  (dolist (value '("" "  " "turbo" "high/max" "very high" 42 high))
    (let ((maduin-config (copy-tree maduin-config)))
      (setcdr (assq 'kiro-effort-low (cdr (assq 'fleet maduin-config))) value)
      (should-not (maduin-config-difficulty-effort 'implementer "ifrit" 'kiro 'low))))
  (let ((maduin-config (copy-tree maduin-config)))
    (setcdr (assq 'effort-low (cdr (assq 'fleet maduin-config))) "minimal")
    (should (equal (maduin-config-difficulty-effort 'implementer "ifrit" 'opencode 'low)
                   "minimal"))
    (setcdr (assq 'effort-low (cdr (assq 'fleet maduin-config))) "xhigh")
    (should-not (maduin-config-difficulty-effort 'implementer "ifrit" 'opencode 'low)))
  (let ((maduin-config (copy-tree maduin-config)))
    (setcdr (assq 'kiro-effort-low (cdr (assq 'fleet maduin-config))) "minimal")
    (should-not (maduin-config-difficulty-effort 'implementer "ifrit" 'kiro 'low)))
  (should-error (maduin-config-difficulty-effort 'implementer 'ifrit 'kiro 'low)
                :type 'user-error))

(ert-deftest maduin-test-config-difficulty-effort-nil-tier ()
  :tags '(maduin)
  (should-not (maduin-config-difficulty-effort 'implementer "ifrit" 'kiro nil))
  (should-not (maduin-config-difficulty-effort 'implementer "ifrit" 'kiro 'medium))
  (should-not (maduin-config-difficulty-effort 'implementer "ifrit" 'foreign 'low)))

(ert-deftest maduin-test-config-fleet-tier-effort-keys ()
  :tags '(maduin)
  (should (equal (maduin-config-option 'fleet 'kiro-effort-low) "medium"))
  (should (equal (maduin-config-option 'fleet 'kiro-effort-high) "high"))
  (should-not (maduin-config-option 'fleet 'effort-low))
  (should-not (maduin-config-option 'fleet 'effort-high)))

(ert-deftest maduin-test-config-tier-schema-rows ()
  :tags '(maduin)
  (dolist (key '(kiro-model-low kiro-model-high
                 kiro-effort-low kiro-effort-high effort-low effort-high))
    (let ((option (cl-find key (maduin-config-options)
                           :key (lambda (entry) (plist-get entry :key)))))
      (should option)
      (should (eq (plist-get option :section) 'fleet))
      (should (eq (plist-get option :type) 'string))
      (should (stringp (plist-get option :label)))
      (should-not (string-empty-p (plist-get option :label))))))

(ert-deftest maduin-test-config-poll-interval ()
  :tags '(maduin)
  (let ((fleet (cdr (assq 'fleet maduin-config))))
    (should (= (alist-get 'poll-interval fleet) 30))))

(ert-deftest maduin-test-config-backend-role-defaults ()
  :tags '(maduin)
  (dolist (role '(implementer designer concierge repairer reviewer))
    (should (eq (maduin-config-role-backend role) 'opencode))))

(ert-deftest maduin-test-config-backend-inherits-role-default ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (setcdr (assq 'backend (cdr (assq 'fleet maduin-config))) 'kiro)
    (should (eq (maduin-config-seat-backend 'implementer "ifrit") 'kiro))))

(ert-deftest maduin-test-config-backend-seat-override-wins ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (setcdr (assq 'backend (cdr (assq 'fleet maduin-config))) 'kiro)
    (maduin-config-set-seat-backend 'implementer "ifrit" 'opencode)
    (should (eq (maduin-config-seat-backend 'implementer "ifrit") 'opencode))
    (should (eq (maduin-config-seat-backend 'implementer "shiva") 'kiro))))

(ert-deftest maduin-test-config-backend-seat-mutation-isolated ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (should (eq (maduin-config-set-seat-backend 'implementer "ifrit" 'kiro)
                'kiro))
    (should (eq (maduin-config-seat-backend 'implementer "ifrit") 'kiro))
    (should (eq (maduin-config-seat-backend 'implementer "shiva") 'opencode))
    (should (eq (maduin-config-role-backend 'implementer) 'opencode))))

(ert-deftest maduin-test-config-backend-invalid-input-does-not-mutate ()
  :tags '(maduin)
  (let* ((maduin-config (copy-tree maduin-config))
         (before (copy-tree maduin-config)))
    (dolist (args '((unknown "ifrit" kiro)
                    (implementer "missing" kiro)
                    (implementer "ifrit" unsupported)
                    (implementer 7 kiro)))
      (should-error (apply #'maduin-config-set-seat-backend args)
                    :type 'user-error)
      (should (equal maduin-config before)))))


(ert-deftest maduin-test-config-crew-backend-unset-preserves-existing-precedence ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (setcdr (assq 'backend (cdr (assq 'fleet maduin-config))) 'kiro)
    (maduin-config-set-seat-backend 'implementer "ifrit" 'opencode)
    (should-not (maduin-config-crew-backend))
    (should (eq (maduin-config-seat-backend 'implementer "ifrit") 'opencode))
    (should (eq (maduin-config-seat-backend 'implementer "shiva") 'kiro))))

(ert-deftest maduin-test-config-crew-backend-overrides-every-seat-and-model ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (dolist (backend '(opencode kiro))
      (maduin-config-set-crew-backend backend)
      (dolist (role '(implementer designer concierge repairer reviewer))
        (dolist (entry (cdr (assq 'seats (maduin-config--section role))))
          (let ((seat (cdr (assq 'name entry))))
            (should (eq (maduin-config-seat-backend role seat) backend))
            (should (equal (maduin-dispatch--seat-model-for role seat)
                           (maduin-config-seat-model role seat backend)))))))))

(ert-deftest maduin-test-config-crew-backend-invalid-input-does-not-mutate ()
  :tags '(maduin)
  (let* ((maduin-config (copy-tree maduin-config))
         (before (copy-tree maduin-config)))
    (dolist (value '(bogus "kiro" 7))
      (should-error (maduin-config-set-crew-backend value) :type 'user-error)
      (should (equal maduin-config before)))))

(ert-deftest maduin-test-config-crew-backend-schema-and-panel-visible ()
  :tags '(maduin)
  (let ((row (maduin-test--cockpit-config-row 'crew 'backend)))
    (should (equal (maduin-config--option-spec 'crew 'backend)
                   '(crew backend "crew-wide backend provider override"
                          backend (opencode kiro))))
    (should row)
    (should (eq (plist-get row :type) 'backend))
    (should-not (plist-get row :value))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _args) "unset")))
      (should-not (maduin-cockpit-config--read row)))))
(ert-deftest maduin-test-config-backend-save-refuses-unsafe-rewrite ()
  :tags '(maduin)
  (let* ((maduin-config (copy-tree maduin-config))
         (before-config (copy-tree maduin-config))
         (before-file (with-temp-buffer
                        (insert-file-contents maduin-config--file)
                        (buffer-string))))
    (should-error (maduin-config-save) :type 'user-error)
    (should (equal maduin-config before-config))
    (should (equal (with-temp-buffer
                     (insert-file-contents maduin-config--file)
                     (buffer-string))
                   before-file))))

(ert-deftest maduin-test-config-role-models-are-backend-specific ()
  :tags '(maduin)
  (dolist (expectation
           '((concierge "opencode-go/deepseek-v4-pro" "gpt-5.6-terra")
             (designer "opencode-go/deepseek-v4-pro" "gpt-5.6-terra")
             (implementer "opencode/deepseek-v4-flash-free" "gpt-5.6-terra")
             (reviewer "opencode-go/deepseek-v4-pro" "gpt-5.6-terra")
             (repairer "opencode-go/deepseek-v4-pro" "gpt-5.6-terra")))
    (pcase-let ((`(,role ,opencode-model ,kiro-model) expectation))
      (should (equal (maduin-config-role-model role 'opencode) opencode-model))
      (should (equal (maduin-config-role-model role 'kiro) kiro-model)))))

(ert-deftest maduin-test-config-seat-models-preserve-opencode-models ()
  :tags '(maduin)
  (dolist (expectation
           '((concierge "alexander" "opencode-go/deepseek-v4-pro")
             (designer "ramuh" "opencode-go/deepseek-v4-pro")
             (implementer "ifrit" "opencode/deepseek-v4-flash-free")
             (reviewer "odin" "opencode-go/deepseek-v4-pro")
             (repairer "phoenix" "opencode-go/deepseek-v4-pro")))
    (pcase-let ((`(,role ,seat ,model) expectation))
      (should (equal (maduin-config-seat-model role seat 'opencode) model)))))

(ert-deftest maduin-test-config-seat-models-resolve-kiro-per-role ()
  :tags '(maduin)
  (dolist (expectation
           '((concierge "alexander" "gpt-5.6-terra")
             (designer "ramuh" "gpt-5.6-terra")
             (implementer "ifrit" "gpt-5.6-terra")
             (reviewer "odin" "gpt-5.6-terra")
             (repairer "phoenix" "gpt-5.6-terra")))
    (pcase-let ((`(,role ,seat ,model) expectation))
      (should (equal (maduin-config-seat-model role seat 'kiro) model)))))

(ert-deftest maduin-test-config-seat-kiro-model-overrides-role ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (nconc (maduin-config--seat 'implementer "ifrit")
           (list (cons 'kiro-model "gpt-5.6-terra")))
    (should (equal (maduin-config-seat-model 'implementer "ifrit" 'kiro)
                   "gpt-5.6-terra"))
    (should (equal (maduin-config-seat-model 'implementer "shiva" 'kiro)
                   "gpt-5.6-terra"))))

(ert-deftest maduin-test-config-seat-kiro-model-requires-explicit-mapping ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (setcdr (assq 'kiro-model (cdr (assq 'fleet maduin-config))) nil)
    (should-error (maduin-config-seat-model 'implementer "ifrit" 'kiro)
                  :type 'user-error)))

(ert-deftest maduin-test-config-option-schema-coverage ()
  :tags '(maduin)
  (dolist (section maduin-config)
    (dolist (cell (cdr section))
      (unless (eq (car cell) 'seats)
        (should (maduin-config--option-spec (car section) (car cell)))))))

(ert-deftest maduin-test-config-option-get ()
  :tags '(maduin)
  (should (= (maduin-config-option 'fleet 'poll-interval) 30)))

(ert-deftest maduin-test-config-option-options ()
  :tags '(maduin)
  (let ((options (maduin-config-options)))
    (should (= (length options) (length maduin-config--option-schema)))
    (should (equal (cl-subseq (car options) 0 12)
                   '(:section harness :key name :label "harness name"
                     :type string :choices nil :value "maduin")))))

(ert-deftest maduin-test-config-option-set ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (should (= (maduin-config-set-option 'fleet 'poll-interval 45) 45))
    (should (= (maduin-config-option 'fleet 'poll-interval) 45))))

(ert-deftest maduin-test-config-option-rejects-invalid-type ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (should-error (maduin-config-set-option 'fleet 'poll-interval "45")
                  :type 'user-error)
    (should (= (maduin-config-option 'fleet 'poll-interval) 30))))

(ert-deftest maduin-test-config-option-rejects-unknown-key ()
  :tags '(maduin)
  (should-error (maduin-config-set-option 'fleet 'nope 1) :type 'user-error))

(ert-deftest maduin-test-config-option-rejects-invalid-choice ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (should-error (maduin-config-set-option 'concierge 'backend 'bogus)
                  :type 'user-error)
    (should (eq (maduin-config-set-option 'concierge 'backend 'kiro) 'kiro))
    (should (eq (maduin-config-option 'concierge 'backend) 'kiro))))

(ert-deftest maduin-test-config-option-adds-missing-key ()
  :tags '(maduin)
  (let ((maduin-config '((fleet . ((agent . "worker"))))))
    (should (= (maduin-config-set-option 'fleet 'poll-interval 45) 45))
    (should (= (maduin-config-option 'fleet 'poll-interval) 45))))

(ert-deftest maduin-test-config-option-save-rejected ()
  :tags '(maduin)
  (should-error (maduin-config-save) :type 'user-error))

;;; 3. state snapshot store

(ert-deftest maduin-test-state-put-get-roundtrip ()
  :tags '(maduin)
  (let ((maduin-state--data nil))
    (should (equal (maduin-state-put 'pipeline '(:queued 3))
                   '(:queued 3)))
    (should (equal (maduin-state-get 'pipeline) '(:queued 3)))
    (should (numberp (maduin-state-fetched-at 'pipeline)))
    (maduin-state-put 'empty nil)
    (should-not (maduin-state-get 'empty :missing))
    (should (numberp (maduin-state-fetched-at 'empty)))
    (should (eq (maduin-state-get 'absent :missing) :missing))))

(ert-deftest maduin-test-state-stale-p-boundary ()
  :tags '(maduin)
  (let ((maduin-state--data nil)
        (maduin-state-ttl 5.0))
    (should (maduin-state-stale-p 'pipeline 5.0 100.0))
    (maduin-state-put 'pipeline 'snapshot)
    (let ((stamp (maduin-state-fetched-at 'pipeline)))
      (should-not (maduin-state-stale-p 'pipeline 5.0 stamp))
      (should-not (maduin-state-stale-p 'pipeline 5.0 (+ stamp 5.0)))
      (should (maduin-state-stale-p 'pipeline 5.0 (+ stamp 5.001))))))

(ert-deftest maduin-test-state-invalidate-key ()
  :tags '(maduin)
  (let ((maduin-state--data nil))
    (maduin-state-put 'pipeline 'snapshot)
    (maduin-state-put 'titles 'cache)
    (maduin-state-invalidate 'pipeline)
    (should (eq (maduin-state-get 'pipeline :missing) :missing))
    (should-not (maduin-state-fetched-at 'pipeline))
    (should (eq (maduin-state-get 'titles) 'cache))))

(ert-deftest maduin-test-state-invalidate-all ()
  :tags '(maduin)
  (let ((maduin-state--data nil))
    (maduin-state-put 'pipeline 'snapshot)
    (maduin-state-put 'titles 'cache)
    (maduin-state-invalidate)
    (should-not maduin-state--data)
    (should-not (maduin-state-fetched-at 'pipeline))
    (should-not (maduin-state-fetched-at 'titles))))

(ert-deftest maduin-test-state-no-subprocess ()
  :tags '(maduin)
  (let ((maduin-state--data nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (error "unexpected subprocess")))
              ((symbol-function 'call-process-shell-command)
               (lambda (&rest _) (error "unexpected subprocess"))))
      (should (eq (maduin-state-get 'pipeline :missing) :missing))
      (maduin-state-put 'pipeline 'snapshot)
      (should (eq (maduin-state-get 'pipeline) 'snapshot))
      (should (numberp (maduin-state-fetched-at 'pipeline)))
      (should-not (maduin-state-stale-p 'pipeline 5.0 (float-time)))
      (maduin-state-invalidate 'pipeline)
      (should (maduin-state-stale-p 'pipeline 5.0 (float-time))))))

;;; 4. bd-bridge

(ert-deftest maduin-test-bd-json-decode-parity ()
  :tags '(maduin)
  (let ((s "[{\"id\":\"t1\",\"title\":\"Maduin \\\"native\\\" JSON ✓\",\"nested\":{\"name\":\"café\"},\"items\":[1,null,false]}]"))
    (let ((json-false nil))
      (should (equal (maduin-bd--json-decode s)
                     (json-read-from-string s))))))

(ert-deftest maduin-test-bd-json-decode-fallback ()
  :tags '(maduin)
  (let ((s "[{\"id\":\"t1\",\"active\":false}]"))
    (cl-letf (((symbol-function 'json-parse-string) nil))
      (let ((json-false nil))
        (should (equal (maduin-bd--json-decode s)
                       (json-read-from-string s)))))))

(ert-deftest maduin-test-bd-json-decode-garbage ()
  :tags '(maduin)
  (should-not (maduin-bd--json-decode "not json"))
  (should-not (maduin-bd--json-decode "")))

(ert-deftest maduin-test-bd-json-data-array ()
  :tags '(maduin)
  (should (equal (maduin-bd--json-data "[{\"id\":\"t1\"}]")
                 '(((id . "t1"))))))

(ert-deftest maduin-test-bd-json-data-non-json ()
  :tags '(maduin)
  (should-not (maduin-bd--json-data "Error: no issue")))

(ert-deftest maduin-test-bd-json-data-empty ()
  :tags '(maduin)
  (should-not (maduin-bd--json-data ""))
  (should-not (maduin-bd--json-data nil)))

(ert-deftest maduin-test-bd-json-data-object ()
  :tags '(maduin)
  (should-not (maduin-bd--json-data "{\"error\":\"x\"}")))

(ert-deftest maduin-test-bd-bridge-functions-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-bd--call
               maduin-bd-list-all
               maduin-bd-ready-tasks
               maduin-bd-claim
               maduin-bd-release
               maduin-bd-close
               maduin-bd-create-epic
               maduin-bd-create-task
               maduin-bd-dep-add
               maduin-bd-show
               maduin-bd-remember
               maduin-bd-prime
               maduin-bd-open-epics
               maduin-bd-epic-children))
    (should (fboundp f))))

(ert-deftest maduin-test-bd-close-writes-no-repo-file ()
  :tags '(maduin)
  ;; The close reason travels through a temp file that is deleted afterwards.
  ;; Nothing may be written into the seat worktree or the repo root: what the
  ;; worker did is recorded in its commit message, not in a tracked file.
  (let* ((dir (maduin-test--temp-dir))
         (seen nil)
         (reason-file nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'maduin-bd--run)
                     (lambda (cmd)
                       (setq seen cmd)
                       (when (string-match "--reason-file \\(.*\\)\\'" cmd)
                         (setq reason-file (match-string 1 cmd))
                         ;; Readable while bd runs, gone afterwards.
                         (should (file-exists-p reason-file)))
                       (cons 0 ""))))
            (should (maduin-bd-close "t1" "landed work" dir)))
          (should (string-match-p "bd close t1 --reason-file " seen))
          (should reason-file)
          (should-not (file-exists-p reason-file))
          (should (null (directory-files dir nil "\\`[^.]" t)))
          (should-not (file-exists-p (expand-file-name "output.md" dir)))
          (should-not (file-exists-p
                       (expand-file-name "output.md" default-directory))))
      (delete-directory dir t))))

(ert-deftest maduin-test-bd-close-file-symbols-are-gone ()
  :tags '(maduin)
  ;; No md-file substrate remains: the defcustom and its path helper are
  ;; deliberately removed rather than left as dead aliases.
  (should-not (boundp 'maduin-bd-close-file))
  (should-not (fboundp 'maduin-bd-close-path)))

(ert-deftest maduin-test-implement-plan-records-work-in-commit ()
  :tags '(maduin)
  (let* ((maduin-dispatch--show-fn
          (lambda (_task) (list :title "T" :desc "D")))
         (plan (maduin-dispatch--implement-plan "task-1")))
    (should (string-match-p "commit message body" plan))
    (should-not (string-match-p "output\\.md" plan))))

(ert-deftest maduin-test-bd-remember-and-forget ()
  :tags '(maduin)
  (let* ((ts (format-time-string "%Y%m%d%H%M%S" (current-time)))
         (fact (format "maduin ERT probe %s" ts))
         (ok (condition-case nil
                 (maduin-bd-remember fact)
               (error nil))))
    (when ok
      (should (eq ok t)))
    (maduin-test--bd-forget-matching "maduin-ert-probe")))

(ert-deftest maduin-test-bd-query-all-flag ()
  :tags '(maduin)
  ;; Default excludes closed; ALL=t must append `--all' so closed children
  ;; are visible (an epic with only-closed children still reports them).
  (let ((seen nil))
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (_prog &rest args)
                 (setq seen args)
                 (cons 0 "[{\"id\":\"t1\"}]"))))
      (should (equal (maduin-bd-query "parent=epic-x") '("t1")))
      (should (member "--json" seen))
      (should-not (member "--all" seen)))
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (_prog &rest args)
                 (setq seen args)
                 (cons 0 "[{\"id\":\"t1\"}]"))))
      (should (equal (maduin-bd-query "parent=epic-x" t) '("t1")))
      (should (member "--all" seen)))))

(ert-deftest maduin-test-bd-epic-children-includes-closed ()
  :tags '(maduin)
  ;; Epic-children MUST include closed children (`--all'), else a done epic
  ;; looks undecomposed and Ramuh re-dispatches decomposition on it.
  (let ((seen nil))
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (_prog &rest args)
                 (setq seen args)
                 (cons 0 "[{\"id\":\"c1\"},{\"id\":\"c2\"}]"))))
      (should (equal (maduin-bd-epic-children "epic-x") '("c1" "c2")))
      (should (member "parent=epic-x" seen))
      (should (member "--all" seen)))))

(ert-deftest maduin-test-bd-call-task-id-as-arg-no-shell ()
  :tags '(maduin)
  ;; maduin-bd--call must hand task-ids to the program as literal arg
  ;; elements (a Lisp list), never interpolated into a shell string, so
  ;; quoting/injection is impossible.  Mock `call-process' to capture the
  ;; exact program and args.
  (let (seen)
    (cl-letf (((symbol-function 'call-process)
               (lambda (program _infile _destination _display &rest args)
                 (setq seen (cons program args))
                 0)))
      (maduin-bd-show "maduin-x59.1")
      (should (equal (car seen) "bd"))
      (should (cl-every #'stringp (cdr seen)))
      (should (member "show" (cdr seen)))
      (should (member "--json" (cdr seen)))
      ;; The task-id arrives as a single argument element, exactly equal.
      (should (member "maduin-x59.1" (cdr seen)))
      (should-not (string-match-p "maduin-x59.1"
                                  (mapconcat #'identity (remove "maduin-x59.1" (cdr seen)) " "))))))

(ert-deftest maduin-test-bd-call-real-program-no-shell ()
  :tags '(maduin)
  ;; maduin-bd--call must run the program directly (no shell): each arg
  ;; arrives verbatim as one element, and shell metacharacters inside an
  ;; arg are inert.  Real subprocess via `call-process', exit+stdout shape
  ;; asserted.  Skips when printf is unavailable (unlikely on macOS/Linux).
  (let ((printf (executable-find "printf")))
    (skip-unless printf)
    (let* ((task-id "maduin-x59.1")
           (toxic "evil; echo hacked >&2 |$(touch pwn)`date` &")
           (args (list "%s\n" task-id toxic))
           (res (apply #'maduin-bd--call printf args)))
      (should (= 0 (car res)))
      (should (stringp (cdr res)))
      ;; One output line per arg, in order, byte-for-byte — proves args
      ;; were handed to the program as list elements, never shell-joined.
      (let ((lines (split-string (cdr res) "\n" t)))
        (should (equal lines (list task-id toxic)))))))

(ert-deftest maduin-test-bd-list-all-single-call-normalized ()
  :tags '(maduin)
  ;; One `bd list --json --all' subprocess yields normalized bead alists —
  ;; callers count statuses client-side instead of 3x `bd count --status'.
  (let ((seen nil))
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (_prog &rest args)
                 (setq seen args)
                 (cons 0 "[{\"id\":\"a\",\"status\":\"closed\"}]"))))
      (should (equal (maduin-bd-list-all)
                     '(((id . "a") (status . "closed"))))))
    (should (equal seen '("list" "--json" "--all")))))

(ert-deftest maduin-test-bd-list-all-failure-nil ()
  :tags '(maduin)
  (cl-letf (((symbol-function 'maduin-bd--call)
             (lambda (&rest _) (cons 1 "boom"))))
    (should-not (maduin-bd-list-all))))

(ert-deftest maduin-test-bd-labels-string-array ()
  :tags '(maduin)
  (let (seen)
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (program &rest args)
                 (setq seen (cons program args))
                 (cons 0 "[\"staged\",\"difficulty:low\"]"))))
      (should (equal (maduin-bd-labels "task-1")
                     '("staged" "difficulty:low")))
      (should (equal seen
                     '("bd" "label" "list" "task-1" "--json"))))))

(ert-deftest maduin-test-bd-labels-object-array ()
  :tags '(maduin)
  (cl-letf (((symbol-function 'maduin-bd--call)
             (lambda (&rest _)
               (cons 0 "[{\"label\":\"staged\"},{\"name\":\"difficulty:high\"},{\"label\":\"\"},{\"name\":7}]"))))
    (should (equal (maduin-bd-labels "task-1")
                   '("staged" "difficulty:high")))))

(ert-deftest maduin-test-bd-labels-empty ()
  :tags '(maduin)
  (dolist (output '("[]" "" "not json"))
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (&rest _) (cons 0 output))))
      (should-not (maduin-bd-labels "task-1")))))

(ert-deftest maduin-test-bd-labels-failure ()
  :tags '(maduin)
  (let (logged)
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (&rest _) (cons 1 "boom")))
              ((symbol-function 'maduin-bd--log-error)
               (lambda (message) (setq logged message))))
      (should-not (maduin-bd-labels "task-1"))
      (should (string-match-p "bd label list task-1 failed" logged)))))

(ert-deftest maduin-test-bd-difficulty-low ()
  :tags '(maduin)
  (cl-letf (((symbol-function 'maduin-bd-labels)
             (lambda (_id) '("difficulty:low"))))
    (should (eq (maduin-bd-difficulty "task-1") 'low)))
  (cl-letf (((symbol-function 'maduin-bd-labels)
             (lambda (_id) '("Difficulty:LOW"))))
    (should (eq (maduin-bd-difficulty "task-1") 'low))))

(ert-deftest maduin-test-bd-difficulty-high ()
  :tags '(maduin)
  (cl-letf (((symbol-function 'maduin-bd-labels)
             (lambda (_id) '("difficulty:high"))))
    (should (eq (maduin-bd-difficulty "task-1") 'high))))

(ert-deftest maduin-test-bd-difficulty-both-tiers-high ()
  :tags '(maduin)
  (cl-letf (((symbol-function 'maduin-bd-labels)
             (lambda (_id) '("difficulty:low" "difficulty:high"))))
    (should (eq (maduin-bd-difficulty "task-1") 'high))))

(ert-deftest maduin-test-bd-difficulty-none ()
  :tags '(maduin)
  (dolist (labels '(("staged") ("difficulty:medium") nil))
    (cl-letf (((symbol-function 'maduin-bd-labels)
               (lambda (_id) labels)))
      (should-not (maduin-bd-difficulty "task-1")))))

(ert-deftest maduin-test-bd-release-resets-status-open ()
  :tags '(maduin)
  ;; Releasing a claim must reset status to open (bd update ID --status open).
  (let ((seen nil))
    (cl-letf (((symbol-function 'maduin-bd--run)
               (lambda (cmd)
                 (setq seen cmd)
                 (cons 0 ""))))
      (should (maduin-bd-release "t1"))
      (should (string-match-p "t1" seen))
      (should (string-match-p "--status open" seen)))))

;;; 4. autonomous session substrate (opencode run + NDJSON)

(ert-deftest maduin-test-session-parse-step-finish-stop ()
  :tags '(maduin)
  (let ((evt (maduin-session--parse-line
              "{\"type\":\"step_finish\",\"sessionID\":\"ses_x\",\"part\":{\"reason\":\"stop\"}}")))
    (should (string= (plist-get evt :type) "step_finish"))
    (should (string= (plist-get evt :session-id) "ses_x"))
    (should (eq (plist-get evt :terminal) 'completed))))

(ert-deftest maduin-test-session-parse-step-finish-error ()
  :tags '(maduin)
  (let ((evt (maduin-session--parse-line
              "{\"type\":\"step_finish\",\"sessionID\":\"ses_x\",\"part\":{\"reason\":\"error\"}}")))
    (should (eq (plist-get evt :terminal) 'failed))))

(ert-deftest maduin-test-session-parse-tool-use-error ()
  :tags '(maduin)
  (let ((evt (maduin-session--parse-line
              "{\"type\":\"tool_use\",\"sessionID\":\"ses_x\",\"part\":{\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"error\"}}}")))
    (should (eq (plist-get evt :terminal) 'failed))))

(ert-deftest maduin-test-session-parse-tool-use-completed ()
  :tags '(maduin)
  (let ((evt (maduin-session--parse-line
              "{\"type\":\"tool_use\",\"sessionID\":\"ses_x\",\"part\":{\"type\":\"tool\",\"tool\":\"write\",\"state\":{\"status\":\"completed\"}}}")))
    (should (eq (plist-get evt :terminal) nil))))

(ert-deftest maduin-test-session-parse-nonterminal ()
  :tags '(maduin)
  (let ((evt (maduin-session--parse-line
              "{\"type\":\"text\",\"sessionID\":\"ses_x\",\"part\":{\"type\":\"text\",\"text\":\"hi\"}}")))
    (should (eq (plist-get evt :terminal) nil))))

(ert-deftest maduin-test-session-parse-garbage ()
  :tags '(maduin)
  (should-not (maduin-session--parse-line "not json at all")))

(ert-deftest maduin-test-session-usage-limit-line ()
  :tags '(maduin)
  (should (maduin-session--usage-limit-line-p
           "{\"type\":\"message.updated\",\"info\":{\"error\":{\"name\":\"APIError\",\"data\":{\"statusCode\":429,\"message\":\"usage limit exceeded\"}}}}"))
  (should (maduin-session--usage-limit-line-p
           "{\"type\":\"session.error\",\"error\":\"rate limit reached\"}"))
  (should (maduin-session--usage-limit-line-p
           "{\"type\":\"message.updated\",\"info\":{\"error\":{\"data\":{\"message\":\"429 Too Many Requests\"}}}}"))
  ;; Model text mentioning 429/error in ordinary output is NOT a limit.
  (should-not (maduin-session--usage-limit-line-p
               "{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"handle HTTP 429 error responses\"}}"))
  ;; Bare failure with no usage/limit signal is NOT a limit.
  (should-not (maduin-session--usage-limit-line-p
               "{\"type\":\"step_finish\",\"part\":{\"reason\":\"error\"}}")))

(ert-deftest maduin-test-session-run-missing-cli ()
  :tags '(maduin)
  (let ((maduin-opencode-command "no-such-opencode-cli-xyz"))
    (should-not (maduin-session-run default-directory "m" nil "p"))))

(ert-deftest maduin-test-session-complete-p-unknown ()
  :tags '(maduin)
  (should (eq (maduin-session-complete-p "no-such-handle-xyz") 'failed)))

(ert-deftest maduin-test-session-diff-unknown ()
  :tags '(maduin)
  (should-not (maduin-session-diff "no-such-handle-xyz")))

(ert-deftest maduin-test-session-run-completes ()
  :tags '(maduin)
  (let* ((shim (maduin-test--fake-opencode-shim))
         (maduin-opencode-command shim)
         (captured nil)
         (maduin-session-on-complete-hook
          (list (lambda (sid status) (setq captured (cons sid status)))))
         (dir (maduin-test--temp-dir))
         (sid (maduin-session-run dir "test-model" nil "say hi"))
         (buf (and sid (maduin-session--run-buffer sid)))
         (proc (and buf (get-buffer-process buf))))
    (unwind-protect
        (progn
          (should (stringp sid))
          (while (and proc (process-live-p proc))
            (accept-process-output proc 0.05))
          (should (eq (maduin-session-complete-p sid) 'completed))
          (should (equal (car captured) sid))
          (should (eq (cdr captured) 'completed))
          (should (maduin-session-diff sid))
          (should (maduin-session-delete sid)))
      (ignore-errors (maduin-session-delete sid))
      (delete-directory dir t))))

(ert-deftest maduin-test-session-run-permission-denied ()
  :tags '(maduin)
  (let* ((shim (maduin-test--fake-opencode-shim))
         (maduin-opencode-command shim)
         (process-environment (cons "MADUIN_FAKE_MODE=fail" process-environment))
         (dir (maduin-test--temp-dir))
         (sid (maduin-session-run dir "test-model" nil "edit file"))
         (buf (and sid (maduin-session--run-buffer sid)))
         (proc (and buf (get-buffer-process buf))))
    (unwind-protect
        (progn
          (should (stringp sid))
          (while (and proc (process-live-p proc))
            (accept-process-output proc 0.05))
          ;; exit code 0 but event stream says failed — exit code untrusted
          (should (eq (maduin-session-complete-p sid) 'failed)))
      (ignore-errors (maduin-session-delete sid))
      (delete-directory dir t))))

(ert-deftest maduin-test-session-opencode-adapter-registered ()
  :tags '(maduin)
  (let ((adapter (maduin-backend-get 'opencode)))
    (should adapter)
    (should (string= (plist-get adapter :executable) maduin-opencode-command))
    (should (eq (plist-get adapter :run-fn) #'maduin-session--opencode-run))
    (should (eq (plist-get adapter :complete-p-fn) #'maduin-session-complete-p))
    (should (eq (plist-get adapter :diff-fn) #'maduin-session-diff))
    (should (eq (plist-get adapter :delete-fn) #'maduin-session-delete))
    (dolist (key '(:run-fn :tui-fn :complete-p-fn :diff-fn :delete-fn))
      (should (functionp (plist-get adapter key))))))

(ert-deftest maduin-test-session-opencode-command-and-ndjson-contract ()
  :tags '(maduin)
  ;; Only terminal NDJSON events decide success; process exit code is irrelevant.
  (should (eq (plist-get (maduin-session--parse-line
                          "{\"type\":\"step_finish\",\"part\":{\"reason\":\"stop\"}}")
                         :terminal)
              'completed))
  (should (eq (plist-get (maduin-session--parse-line
                          "{\"type\":\"tool_use\",\"part\":{\"state\":{\"status\":\"error\"}}}")
                         :terminal)
              'failed)))

(ert-deftest maduin-test-session-run-command-nil-effort-unchanged ()
  :tags '(maduin)
  (should
   (equal (maduin-session--opencode-run-command
           "opencode" "/w" "m" "" "h" "p")
          '("opencode" "run" "--dir" "/w" "-m" "m"
            "--format" "json" "--auto" "--title" "h" "p"))))

(ert-deftest maduin-test-session-run-command-with-effort ()
  :tags '(maduin)
  (should
   (equal (maduin-session--opencode-run-command
           "opencode" "/w" "m" nil "h" "p" "high")
          '("opencode" "run" "--dir" "/w" "-m" "m" "--variant" "high"
            "--format" "json" "--auto" "--title" "h" "p"))))

(ert-deftest maduin-test-session-run-command-effort-position ()
  :tags '(maduin)
  (should
   (equal (maduin-session--opencode-run-command
           "opencode" "/w" "m" "a" "h" "p" "high")
          '("opencode" "run" "--dir" "/w" "-m" "m" "--variant" "high"
            "--agent" "a" "--format" "json" "--auto" "--title" "h" "p"))))

(ert-deftest maduin-test-session-run-command-invalid-effort-omitted ()
  :tags '(maduin)
  (let ((expected '("opencode" "run" "--dir" "/w" "-m" "m"
                    "--format" "json" "--auto" "--title" "h" "p")))
    (dolist (effort (list nil "" "  " "a b" "hi/gh" 'high))
      (should (equal (maduin-session--opencode-run-command
                      "opencode" "/w" "m" nil "h" "p" effort)
                     expected)))))

(ert-deftest maduin-test-session-opencode-effort-optional-arity ()
  :tags '(maduin)
  (let ((maduin-opencode-command "no-such-opencode-cli-xyz")
        (adapter (maduin-backend-get 'opencode)))
    (should-not (maduin-session--opencode-run "/w" "m" nil "p"))
    (should-not (maduin-session--opencode-run "/w" "m" nil "p" "high"))
    (should-not (maduin-session-run "/w" "m" nil "p"))
    (should-not (maduin-session-run "/w" "m" nil "p" "high"))
    (should (string-match-p
             "--variant high"
             (funcall (plist-get adapter :tui-fn) "/w" "m" nil "p" "high")))))

(ert-deftest maduin-test-session-completion-hook-runs-once ()
  :tags '(maduin)
  (let* ((shim (maduin-test--fake-opencode-shim))
         (maduin-opencode-command shim)
         (calls 0)
         (maduin-session-on-complete-hook
          (list (lambda (_sid _status) (cl-incf calls))))
         (dir (maduin-test--temp-dir))
         (sid (maduin-session-run dir "test-model" nil "say hi"))
         (buf (and sid (maduin-session--run-buffer sid)))
         (proc (and buf (get-buffer-process buf))))
    (unwind-protect
        (progn
          (while (and proc (process-live-p proc))
            (accept-process-output proc 0.05))
          ;; A duplicate sentinel notification cannot repeat the hook.
          (maduin-session--run-sentinel proc "finished\n")
          (should (= calls 1)))
      (ignore-errors (maduin-session-delete sid))
      (delete-directory dir t))))

(ert-deftest maduin-test-session-diff-delete-cleans-registry ()
  :tags '(maduin)
  (let* ((shim (maduin-test--fake-opencode-shim))
         (maduin-opencode-command shim)
         (dir (maduin-test--temp-dir))
         (sid (maduin-session-run dir "test-model" nil "say hi"))
         (buf (and sid (maduin-session--run-buffer sid)))
         (proc (and buf (get-buffer-process buf))))
    (unwind-protect
        (progn
          (while (and proc (process-live-p proc))
            (accept-process-output proc 0.05))
          (should (maduin-session-diff sid))
          (should (maduin-session-delete sid))
          (should-not (gethash sid maduin-session--registry))
          (should-not (buffer-live-p buf))
          (should-not (maduin-session-diff sid))
          (should-not (maduin-session-delete sid)))
      (ignore-errors (maduin-session-delete sid))
      (delete-directory dir t))))

;;; 6. handoff

(ert-deftest maduin-test-handoff-write-read ()
  :tags '(maduin)
  (let ((dir (maduin-test--temp-dir)))
    (unwind-protect
        (let ((default-directory dir))
          (should (maduin-handoff-write "test-seat" "handoff body"))
          (should (string= (maduin-handoff-read "test-seat")
                           "handoff body")))
      (delete-directory dir t))))

(ert-deftest maduin-test-handoff-read-missing ()
  :tags '(maduin)
  (let ((dir (maduin-test--temp-dir)))
    (unwind-protect
        (let ((default-directory dir))
          (should (null (maduin-handoff-read "ghost-seat"))))
      (delete-directory dir t))))

;;; 7. pipeline

(ert-deftest maduin-test-pipeline-status-keys ()
  :tags '(maduin)
  (let ((maduin-state--data nil)
        (maduin-pipeline--seats-cache nil))
    (let ((status (maduin-pipeline-status)))
      (should (listp status))
      (dolist (k '(:queued :active :completed :blocked :fleet-free :fleet-busy))
        (should (plist-member status k))))))

(ert-deftest maduin-test-pipeline-status-pure ()
  :tags '(maduin)
  (let* ((snapshot '(:queued 4 :active 3 :completed 2 :blocked 1
                     :fleet-free 2 :fleet-busy 1))
         (maduin-state--data (list 'pipeline snapshot)))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (error "unexpected subprocess")))
              ((symbol-function 'call-process-shell-command)
               (lambda (&rest _) (error "unexpected subprocess"))))
      (should (equal (maduin-pipeline-status) snapshot)))))

(ert-deftest maduin-test-pipeline-status-refresh-merges ()
  :tags '(maduin)
  (let ((maduin-state--data nil)
        (maduin-pipeline--status-refreshing nil)
        (calls 0)
        (puts 0)
        (put (symbol-function 'maduin-state-put)))
    (cl-letf (((symbol-function 'maduin-pipeline-fleet-seats)
               (lambda () '("ifrit" "shiva" "titan")))
              ((symbol-function 'maduin-bd-async-json-valid)
               (lambda (args callback)
                 (cl-incf calls)
                 (funcall callback
                          (if (equal (car args) "ready")
                              '((id . "q1") (id . "q2"))
                            '(((status . "closed"))
                              ((status . "closed"))
                              ((status . "in_progress"))
                              ((status . "blocked"))))
                          0 t)
                 :started))
              ((symbol-function 'maduin-state-put)
               (lambda (key value)
                 (cl-incf puts)
                 (funcall put key value))))
      (maduin-pipeline-status-refresh)
      (should (= calls 2))
      (should (= puts 1))
      (should (equal (maduin-state-get 'pipeline)
                     '(:queued 2 :active 1 :completed 2 :blocked 1
                       :fleet-free 3 :fleet-busy 0))))))

(ert-deftest maduin-test-pipeline-status-refresh-accepts-empty-arrays ()
  :tags '(maduin)
  (let ((maduin-state--data nil) (maduin-pipeline--status-refreshing nil))
    (cl-letf (((symbol-function 'maduin-pipeline-fleet-seats) (lambda () '("ifrit")))
              ((symbol-function 'maduin-bd-async-json-valid)
               (lambda (_args callback) (funcall callback nil 0 t) :started)))
      (maduin-pipeline-status-refresh)
      (should (equal (maduin-state-get 'pipeline)
                     '(:queued 0 :active 0 :completed 0 :blocked 0
                       :fleet-free 1 :fleet-busy 0))))))

(ert-deftest maduin-test-pipeline-status-refresh-partial-failure ()
  :tags '(maduin)
  (let* ((previous '(:queued 9 :active 8 :completed 7 :blocked 6
                     :fleet-free 5 :fleet-busy 4))
         (maduin-state--data (list 'pipeline previous))
         (maduin-pipeline--status-refreshing nil)
         (puts 0)
         (put (symbol-function 'maduin-state-put)))
    (cl-letf (((symbol-function 'maduin-bd-async-json-valid)
               (lambda (args callback)
                 (funcall callback
                          (and (equal (car args) "ready") '((id . "q1")))
                          (if (equal (car args) "ready") 0 1)
                          (equal (car args) "ready"))
                 :started))
              ((symbol-function 'maduin-state-put)
               (lambda (key value)
                 (cl-incf puts)
                 (funcall put key value))))
      (maduin-pipeline-status-refresh)
      (should (= puts 0))
      (should (equal (maduin-state-get 'pipeline) previous)))))

(ert-deftest maduin-test-pipeline-status-refresh-skips-when-fresh ()
  :tags '(maduin)
  (let ((maduin-state--data
         (list 'pipeline '(:queued 1) :pipeline-at (float-time)))
        (maduin-pipeline--status-refreshing nil)
        (calls 0))
    (cl-letf (((symbol-function 'maduin-bd-async-json)
               (lambda (&rest _) (cl-incf calls))))
      (maduin-pipeline-status-refresh)
      (should (= calls 0)))))

(ert-deftest maduin-test-pipeline-seats-memoized ()
  :tags '(maduin)
  (let ((maduin-pipeline--config-generation 0)
        (maduin-pipeline--config-cache nil)
        (maduin-pipeline--seats-cache nil)
        (traversals 0)
        (section (symbol-function 'maduin-pipeline--config-section)))
    (cl-letf (((symbol-function 'maduin-pipeline--config-section)
               (lambda (name)
                 (cl-incf traversals)
                 (funcall section name))))
      (dotimes (_ 10) (maduin-pipeline-fleet-seats))
      (should (= traversals 1))
      (maduin-pipeline-config-bump)
      (maduin-pipeline-fleet-seats)
      (should (= traversals 2)))))

(ert-deftest maduin-test-pipeline-fleet-seats ()
  :tags '(maduin)
  (should (equal (maduin-pipeline-fleet-seats)
                 '("ifrit" "shiva" "titan"))))

(ert-deftest maduin-test-pipeline-fleet-busy-dispatch ()
  :tags '(maduin)
  ;; Fleet busy must read the dispatch active registry (demand-driven
  ;; source of truth), not legacy seat-buffer sessions.
  (let ((maduin-dispatch--active
         '((:handle "h1" :seat "ifrit" :role implementer :task "bd-1")
           (:handle "h2" :seat "shiva" :role designer :task "bd-2"))))
    (should (= (maduin-pipeline--fleet-busy-count) 1)))
  (let ((maduin-dispatch--active nil))
    (should (= (maduin-pipeline--fleet-busy-count) 0))))

(ert-deftest maduin-test-pipeline-count-statuses-client-side ()
  :tags '(maduin)
  ;; Fixture alists → correct counts, no bd subprocesses.  Status matches
  ;; bd's stored status strings (underscore: in_progress), which is what
  ;; `bd list --json --all' emits.
  (let ((data (list (list (cons 'status "closed") (cons 'id "c1"))
                    (list (cons 'status "in_progress") (cons 'id "i1"))
                    (list (cons 'status "blocked") (cons 'id "b1"))
                    (list (cons 'status "closed") (cons 'id "c2"))
                    (list (cons 'status "open") (cons 'id "o1"))
                    (list (cons 'status "deferred") (cons 'id "d1")))))
    (should (= (maduin-pipeline--count data "closed") 2))
    (should (= (maduin-pipeline--count data "in_progress") 1))
    (should (= (maduin-pipeline--count data "blocked") 1))
    (should (= (maduin-pipeline--count data "open") 1))
    (should (= (maduin-pipeline--count data "deferred") 1))
    (should (= (maduin-pipeline--count data "queued") 0)))
  ;; Nil data (failed list call) counts as zero.
  (should (= (maduin-pipeline--count nil "closed") 0)))

(ert-deftest maduin-test-pipeline-status-at-most-two-bd-calls ()
  :tags '(maduin)
  ;; One refresh = `bd ready' + one `bd list --json --all' (≤ 2 calls),
  ;; statuses derived client-side from the list result's status field.
  (let ((calls 0))
    (cl-letf (((symbol-function 'maduin-bd--call)
               (lambda (_prog &rest args)
                 (cl-incf calls)
                 (if (member "ready" args)
                     (cons 0 "[{\"id\":\"q1\"},{\"id\":\"q2\"}]")
                   (cons 0 "[{\"id\":\"c1\",\"status\":\"closed\"},
                             {\"id\":\"c2\",\"status\":\"closed\"},
                             {\"id\":\"i1\",\"status\":\"in_progress\"},
                             {\"id\":\"b1\",\"status\":\"blocked\"}]"))))
              ((symbol-value 'maduin-dispatch--active) nil))
      (let ((st (maduin-pipeline-status-sync)))
        (should (<= calls 2))
        (should (= (plist-get st :queued) 2))
        (should (= (plist-get st :active) 1))
        (should (= (plist-get st :completed) 2))
        (should (= (plist-get st :blocked) 1))))))

;;; 8. cockpit

(ert-deftest maduin-test-cockpit-show ()
  :tags '(maduin)
  (condition-case nil
      (maduin-cockpit-show)
    (error nil))
  (should (get-buffer "*maduin-cockpit*"))
  (when (get-buffer "*maduin-cockpit*")
    (kill-buffer "*maduin-cockpit*")))

(ert-deftest maduin-test-cockpit-refresh-no-subprocess ()
  :tags '(maduin)
  (let ((buf (generate-new-buffer " *maduin-cockpit-no-subprocess*"))
        (maduin-dispatch--active nil))
    (unwind-protect
        (cl-letf (((symbol-function 'call-process)
                   (lambda (&rest _) (error "unexpected subprocess")))
                  ((symbol-function 'call-process-shell-command)
                   (lambda (&rest _) (error "unexpected subprocess")))
                  ((symbol-function 'make-process)
                   (lambda (&rest _) (error "unexpected subprocess")))
                  ((symbol-function 'maduin-pipeline-status)
                   (lambda () '(:queued 0 :active 0 :completed 0 :blocked 0
                                :fleet-free 0 :fleet-busy 0))))
          (with-current-buffer buf
            (tabulated-list-mode)
            (maduin-cockpit-refresh)
            (maduin-cockpit-refresh)))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-refresh-single-status-read ()
  :tags '(maduin)
  (let ((buf (generate-new-buffer " *maduin-cockpit-one-status*"))
        (reads 0)
        (maduin-dispatch--active nil))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-pipeline-status)
                   (lambda ()
                     (cl-incf reads)
                     '(:queued 0 :active 0 :completed 0 :blocked 0
                       :fleet-free 0 :fleet-busy 0))))
          (with-current-buffer buf
            (tabulated-list-mode)
            (maduin-cockpit-refresh)
            (should (= reads 1))
            (maduin-cockpit-refresh)
            (should (= reads 2))))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-refresh-skips-print-when-unchanged ()
  :tags '(maduin)
  (let ((buf (generate-new-buffer " *maduin-cockpit-dirty-check*"))
        (prints 0)
        (maduin-dispatch--active nil))
    (unwind-protect
        (let ((print (symbol-function 'tabulated-list-print)))
          (cl-letf (((symbol-function 'maduin-pipeline-status)
                     (lambda () '(:queued 0 :active 0 :completed 0 :blocked 0
                                  :fleet-free 0 :fleet-busy 0)))
                    ((symbol-function 'tabulated-list-print)
                     (lambda (&rest args)
                       (cl-incf prints)
                       (apply print args))))
            (with-current-buffer buf
              (tabulated-list-mode)
              (maduin-cockpit-refresh)
              (maduin-cockpit-refresh)
              (should (= prints 1)))))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-refresh-prints-on-change ()
  :tags '(maduin)
  (let ((buf (generate-new-buffer " *maduin-cockpit-dirty-change*"))
        (prints 0)
        (status '(:queued 0 :active 0 :completed 0 :blocked 0
                  :fleet-free 0 :fleet-busy 0))
        (maduin-dispatch--active nil))
    (unwind-protect
        (let ((print (symbol-function 'tabulated-list-print)))
          (cl-letf (((symbol-function 'maduin-pipeline-status)
                     (lambda () status))
                    ((symbol-function 'tabulated-list-print)
                     (lambda (&rest args)
                       (cl-incf prints)
                       (apply print args))))
            (with-current-buffer buf
              (tabulated-list-mode)
              (maduin-cockpit-refresh)
              (setq status '(:queued 1 :active 0 :completed 0 :blocked 0
                             :fleet-free 0 :fleet-busy 0))
              (maduin-cockpit-refresh)
              (should (= prints 2)))))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-header-cache-updates ()
  :tags '(maduin)
  (let ((buf (generate-new-buffer " *maduin-cockpit-header-cache*"))
        (updates 0)
        (status '(:queued 0 :active 0 :completed 0 :blocked 0
                  :fleet-free 0 :fleet-busy 0))
        (maduin-dispatch--active nil))
    (unwind-protect
        (cl-letf (((symbol-function 'force-mode-line-update)
                   (lambda (&optional _) (cl-incf updates))))
          (with-current-buffer buf
            (tabulated-list-mode)
            (setq updates 0)
            (maduin-cockpit--render-header status)
            (should (string-match-p "queued 0" maduin-cockpit--header-cache))
            (should (= updates 1))
            (maduin-cockpit--render-header status)
            (should (= updates 1))
            (setq status '(:queued 2 :active 0 :completed 0 :blocked 0
                           :fleet-free 0 :fleet-busy 0))
            (maduin-cockpit--render-header status)
            (should (string-match-p "queued 2" maduin-cockpit--header-cache))
            (should (= updates 2))))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-render-signature-invalidates-on-format-state-and-face ()
  :tags '(maduin)
  (let ((buf (generate-new-buffer " *maduin-cockpit-signature*")))
    (unwind-protect
        (with-current-buffer buf
          (tabulated-list-mode)
          (setq-local maduin-cockpit--render-signature 'old)
          (setq tabulated-list-format nil)
          (maduin-cockpit--ensure-format)
          (should-not maduin-cockpit--render-signature)
          (setq-local maduin-cockpit--render-signature 'old)
          (maduin-cockpit--register-live-updates)
          (maduin-state-invalidate 'pipeline)
          (should-not maduin-cockpit--render-signature)
          (setq-local maduin-cockpit--render-signature 'old)
          (run-hooks 'maduin-cockpit-face-adapt-hook)
          (should-not maduin-cockpit--render-signature))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-refresh-no-error ()
  :tags '(maduin)
  (let ((buf (get-buffer-create "*maduin-cockpit*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (tabulated-list-mode))
          (condition-case nil
              (progn (maduin-cockpit-refresh) (should t))
            (error (should t))))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-refresh-interval-bound ()
  :tags '(maduin)
  (should (integerp maduin-cockpit-refresh-interval))
  (should (> maduin-cockpit-refresh-interval 0)))

(ert-deftest maduin-test-cockpit-timer-start-stop ()
  :tags '(maduin)
  (unwind-protect
      (progn
        (maduin-cockpit--start-timer)
        (should maduin-cockpit--timer)
        (should (timerp maduin-cockpit--timer))
        ;; Idempotent: starting twice keeps one timer.
        (let ((t1 maduin-cockpit--timer))
          (maduin-cockpit--start-timer)
          (should (eq t1 maduin-cockpit--timer)))
        (maduin-cockpit--stop-timer)
        (should (null maduin-cockpit--timer)))
    (when maduin-cockpit--timer
      (cancel-timer maduin-cockpit--timer)
      (setq maduin-cockpit--timer nil))))

(ert-deftest maduin-test-cockpit-auto-refresh-cancels-when-hidden ()
  :tags '(maduin)
  ;; In batch (no windows) the buffer is never visible, so one tick must
  ;; cancel the timer instead of refreshing (prevents timer leak).
  (unwind-protect
      (progn
        (maduin-cockpit--start-timer)
        (maduin-cockpit--auto-refresh)
        (should (null maduin-cockpit--timer)))
    (when maduin-cockpit--timer
      (cancel-timer maduin-cockpit--timer)
      (setq maduin-cockpit--timer nil))))

(ert-deftest maduin-test-cockpit-auto-refresh-skips-inbox ()
  :tags '(maduin)
  (let ((maduin-cockpit-buffer-name " *maduin-cockpit-auto-inbox*")
        (maduin-cockpit--inbox-buffer-name " *maduin-cockpit-auto-chaplet*")
        (calls 0))
    (let ((cockpit (get-buffer-create maduin-cockpit-buffer-name))
          (inbox (get-buffer-create maduin-cockpit--inbox-buffer-name)))
      (unwind-protect
          (progn
            (with-current-buffer inbox
              (setq-local major-mode 'chaplet-list-mode))
            (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) t))
                      ((symbol-function 'maduin-pipeline-status-refresh) #'ignore)
                      ((symbol-function 'maduin-cockpit--schedule-refresh) #'ignore)
                      ((symbol-function 'chaplet-list-refresh)
                       (lambda () (cl-incf calls))))
              (maduin-cockpit--auto-refresh)
              (should (= calls 0))))
        (when (buffer-live-p cockpit) (kill-buffer cockpit))
        (when (buffer-live-p inbox) (kill-buffer inbox))))))

(ert-deftest maduin-test-cockpit-interactive-refresh-refreshes-inbox ()
  :tags '(maduin)
  (let ((maduin-cockpit--inbox-buffer-name " *maduin-cockpit-refresh-chaplet*")
        (calls 0))
    (let ((cockpit (generate-new-buffer " *maduin-cockpit-interactive*"))
          (inbox (get-buffer-create maduin-cockpit--inbox-buffer-name)))
      (unwind-protect
          (progn
            (with-current-buffer inbox
              (setq-local major-mode 'chaplet-list-mode))
            (cl-letf (((symbol-function 'maduin-pipeline-status)
                       (lambda () '(:queued 0 :active 0 :completed 0 :blocked 0
                                    :fleet-free 0 :fleet-busy 0)))
                      ((symbol-function 'maduin-cockpit--rows) (lambda () nil))
                      ((symbol-function 'chaplet-list-refresh)
                       (lambda () (cl-incf calls))))
              (with-current-buffer cockpit
                (tabulated-list-mode)
                (maduin-cockpit-refresh)
                (should (= calls 0))
                ;; The command supplies this explicit argument via its
                ;; interactive form; scheduled callers leave it nil.
                (maduin-cockpit-refresh t)
                (should (= calls 1)))))
        (when (buffer-live-p cockpit) (kill-buffer cockpit))
        (when (buffer-live-p inbox) (kill-buffer inbox))))))

(ert-deftest maduin-test-cockpit-inbox-command-refreshes ()
  :tags '(maduin)
  (let ((maduin-cockpit--inbox-buffer-name " *maduin-cockpit-command-chaplet*")
        (calls 0)
        (message-text nil))
    (let ((cockpit (generate-new-buffer " *maduin-cockpit-command*"))
          (inbox (get-buffer-create maduin-cockpit--inbox-buffer-name)))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer cockpit)
            (let ((inbox-window (split-window-below)))
              (set-window-buffer inbox-window inbox)
              (with-current-buffer inbox
                (setq-local major-mode 'chaplet-list-mode))
              (cl-letf (((symbol-function 'chaplet-list-refresh)
                         (lambda () (cl-incf calls))))
                (maduin-cockpit-inbox)
                (should (eq (selected-window) inbox-window))
                (should (= calls 1)))
              (kill-buffer inbox)
              (setq calls 0)
              (cl-letf (((symbol-function 'message)
                         (lambda (format-string &rest args)
                           (setq message-text (apply #'format format-string args))))
                        ((symbol-function 'chaplet-list-refresh)
                         (lambda () (cl-incf calls))))
                (maduin-cockpit-inbox)
                (should (= calls 0))
                (should (equal message-text "maduin-cockpit: no inbox present")))))
        (when (buffer-live-p cockpit) (kill-buffer cockpit))
        (when (buffer-live-p inbox) (kill-buffer inbox))))))

(ert-deftest maduin-test-cockpit-inbox-timer-optional ()
  :tags '(maduin)
  (let ((maduin-cockpit-inbox-refresh-interval nil)
        (maduin-cockpit--inbox-timer nil))
    (maduin-cockpit--start-inbox-timer)
    (should-not maduin-cockpit--inbox-timer))
  (let ((maduin-cockpit-buffer-name " *maduin-cockpit-inbox-timer*")
        (maduin-cockpit-inbox-refresh-interval 60)
        (maduin-cockpit--timer nil)
        (maduin-cockpit--inbox-timer nil)
        (maduin-cockpit--pending-render nil))
    (unwind-protect
        (save-window-excursion
          (cl-letf (((symbol-function 'maduin-cockpit--register-live-updates) #'ignore)
                    ((symbol-function 'maduin-pipeline-status-refresh) #'ignore)
                    ((symbol-function 'maduin-cockpit-refresh) #'ignore)
                    ((symbol-function 'maduin-cockpit--start-timer) #'ignore)
                    ((symbol-function 'maduin-cockpit--embed-inbox) #'ignore))
            (maduin-cockpit-show)
            (should (timerp maduin-cockpit--inbox-timer))
            (kill-buffer (get-buffer maduin-cockpit-buffer-name))
            (should-not maduin-cockpit--inbox-timer)))
      (when maduin-cockpit--inbox-timer
        (cancel-timer maduin-cockpit--inbox-timer)
        (setq maduin-cockpit--inbox-timer nil)))))

;;; 8a. cockpit-concierge-entry

(ert-deftest maduin-test-cockpit-concierge-bindings ()
  :tags '(maduin)
  (dolist (binding '(("a" . maduin-concierge)
                     ("A" . maduin-concierge-dismiss)
                     ("n" . maduin-designer-drop-in)
                     ("p" . maduin-designer-pending-tasks)))
    (should (eq (lookup-key maduin-cockpit-map (kbd (car binding)))
                (cdr binding))))
  (should-not (member "a" maduin-cockpit--evil-suppress-keys))
  (should-not (member "A" maduin-cockpit--evil-suppress-keys))
  (should-not (member "n" maduin-cockpit--evil-suppress-keys))
  (should-not (member "p" maduin-cockpit--evil-suppress-keys))
  (let ((recorded nil))
    (cl-letf (((symbol-function 'featurep) (lambda (f &optional _s) (eq f 'evil)))
              ((symbol-function 'fboundp) (lambda (f) (eq f 'evil-define-key*)))
              ((symbol-function 'evil-define-key*)
               (lambda (state _map key def) (push (list state key def) recorded))))
      (maduin-cockpit--evil-setup))
    (dolist (binding '(("a" . maduin-concierge)
                       ("A" . maduin-concierge-dismiss)
                       ("n" . maduin-designer-drop-in)
                       ("p" . maduin-designer-pending-tasks)))
      (dolist (state '(normal motion))
        (should (member (list state (kbd (car binding)) (cdr binding)) recorded))))))

(ert-deftest maduin-test-cockpit-concierge-hint-labels ()
  :tags '(maduin)
  (dolist (expectation '((maduin-concierge . "concierge")
                         (maduin-concierge-dismiss . "dismiss")
                         (maduin-designer-drop-in . "design drop-in")
                         (maduin-designer-pending-tasks . "pending")))
    (should (equal (alist-get (car expectation) maduin-cockpit-bar--labels)
                   (cdr expectation)))))

(ert-deftest maduin-test-cockpit-empty-state-cue-and-row-id ()
  :tags '(maduin)
  (let ((buf (generate-new-buffer " *maduin-cockpit-empty*"))
        (maduin-dispatch--active nil))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-cockpit--seats)
                   (lambda () '(("alexander" . "concierge"))))
                  ((symbol-function 'maduin-pipeline-status)
                   (lambda () '(:queued 0 :active 0 :completed 0 :blocked 0
                                :fleet-free 0 :fleet-busy 0))))
          (with-current-buffer buf
            (tabulated-list-mode)
            (maduin-cockpit-refresh)
            (maduin-cockpit-refresh)
            (should (= (how-many "no work in flight" (point-min) (point-max)) 1))
            (goto-char (point-min))
            (should (search-forward "alexander" nil t))
            (goto-char (match-beginning 0))
            (should (equal (tabulated-list-get-id) "alexander"))))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-empty-state-absent-while-active ()
  :tags '(maduin)
  (let ((buf (generate-new-buffer " *maduin-cockpit-active*"))
        (maduin-dispatch--active
         (list (list :seat "alexander" :role 'concierge :status 'working))))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-cockpit--seats)
                   (lambda () '(("alexander" . "concierge"))))
                  ((symbol-function 'maduin-pipeline-status)
                   (lambda () '(:queued 0 :active 1 :completed 0 :blocked 0
                                :fleet-free 0 :fleet-busy 0))))
          (with-current-buffer buf
            (tabulated-list-mode)
            (maduin-cockpit-refresh)
            (should-not (string-match-p "no work in flight" (buffer-string)))))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-concierge-liveness-rendering ()
  :tags '(maduin)
  (let* ((seat "alexander")
         (name (maduin-terminal--buffer-name 'concierge seat))
         (terminal (generate-new-buffer name))
         (maduin-dispatch--active nil))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-cockpit--seats)
                   (lambda () (list (cons seat "concierge")))))
          (let* ((row (car (maduin-cockpit--rows)))
                 (status (aref (cadr row) 2)))
            (should (equal status "discussing"))
            (should (eq (get-text-property 0 'face status)
                        'maduin-cockpit-state-running)))
          (kill-buffer terminal)
          (should (equal (aref (cadr (car (maduin-cockpit--rows))) 2) "dead")))
      (when (buffer-live-p terminal) (kill-buffer terminal)))))

(ert-deftest maduin-test-cockpit-empty-state-cue-face ()
  :tags '(maduin)
  (should (facep 'maduin-cockpit-cue))
  (dolist (palette '(dark light))
    (should (assq 'maduin-cockpit-cue
                  (cdr (assq palette maduin-cockpit-face--palette)))))
  (should-not (memq 'maduin-cockpit-cue maduin-cockpit-face--pill-faces)))

;;; 8b. cockpit-face

(ert-deftest maduin-test-cockpit-face-state-face-known ()
  :tags '(maduin)
  (dolist (s '(dead idle working running repairing))
    (should (facep (maduin-cockpit-state-face s))))
  (should (null (maduin-cockpit-state-face 'unknown)))
  (should (null (maduin-cockpit-state-face nil))))

(ert-deftest maduin-test-cockpit-face-state-color-known ()
  :tags '(maduin)
  (dolist (s '(dead idle working running repairing))
    (let ((c (maduin-cockpit-state-color s)))
      (should (stringp c))
      (should (> (length c) 0))))
  (should (null (maduin-cockpit-state-color 'unknown)))
  (should (null (maduin-cockpit-state-color nil))))

(ert-deftest maduin-test-cockpit-face-chip-face-known ()
  :tags '(maduin)
  (dolist (k '(queued active completed blocked fleet-free fleet-busy))
    (should (facep (maduin-cockpit-chip-face k))))
  (should (null (maduin-cockpit-chip-face 'unknown))))

(ert-deftest maduin-test-cockpit-face-setup-creates-all ()
  :tags '(maduin)
  (maduin-cockpit-face-setup)
  (dolist (f maduin-cockpit-face--pill-faces)
    (should (facep f))))

(ert-deftest maduin-test-cockpit-face-adapt-batch-safe ()
  :tags '(maduin)
  (condition-case nil
      (progn (maduin-cockpit-face-adapt) (should t))
    (error (should nil))))

(ert-deftest maduin-test-cockpit-face-adapt-pill-box ()
  :tags '(maduin)
  (maduin-cockpit-face-adapt)
  (if (display-graphic-p)
      (dolist (f maduin-cockpit-face--pill-faces)
        (should (eq (face-attribute f :box nil 'default) t)))
    (should t)))

;;; 8c. cockpit-rich

(ert-deftest maduin-test-cockpit-seat-status-rich ()
  :tags '(maduin)
  (let ((maduin-state--data nil)
        (maduin-cockpit--title-queue nil)
        (maduin-cockpit--title-requested (make-hash-table :test #'equal))
        (maduin-dispatch--active
         (list (list :handle "s-1" :seat "ifrit" :role 'implementer :task "t1"))))
    (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil)))
      (let ((st (maduin-cockpit--seat-status "ifrit")))
        (should (equal (plist-get st :seat) "ifrit"))
        (should (eq (plist-get st :role) 'implementer))
        (should (eq (plist-get st :status) 'working))
        (should (equal (plist-get st :task-id) "t1"))
        (should-not (plist-get st :task-title))
        (should (null (plist-get st :model)))
        (should (null (plist-get st :uptime)))
        (should (null (plist-get st :phase)))))))

(ert-deftest maduin-test-cockpit-idle-models-use-effective-config ()
  :tags '(maduin)
  (let ((maduin-dispatch--active nil))
    (dolist (expectation
             '(("alexander" . "opencode-go/deepseek-v4-pro")
               ("ramuh" . "opencode-go/deepseek-v4-pro")
               ("ifrit" . "opencode/deepseek-v4-flash-free")
               ("shiva" . "opencode/deepseek-v4-flash-free")
               ("titan" . "opencode/deepseek-v4-flash-free")))
      (let* ((seat (car expectation))
             (status (maduin-cockpit--seat-status seat))
             (row (assoc seat (maduin-cockpit--rows))))
        (should (equal (plist-get status :model) (cdr expectation)))
        (should (equal (aref (cadr row) 4) (cdr expectation)))))))

(ert-deftest maduin-test-cockpit-idle-models-follow-crew-backend ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config))
        (maduin-dispatch--active nil))
    (dolist (expectation
             '((opencode "opencode-go/deepseek-v4-pro"
                         "opencode/deepseek-v4-flash-free")
               (kiro "gpt-5.6-terra" "gpt-5.6-terra")))
      (pcase-let ((`(,backend ,planner-model ,worker-model) expectation))
        (maduin-config-set-crew-backend backend)
        (dolist (seat-model `(("alexander" . ,planner-model)
                              ("ifrit" . ,worker-model)))
          (let ((status (maduin-cockpit--seat-status (car seat-model))))
            (should (eq (plist-get status :backend) backend))
            (should (equal (plist-get status :model) (cdr seat-model)))))))))

(ert-deftest maduin-test-cockpit-idle-model-malformed-config-is-safe ()
  :tags '(maduin)
  (let ((maduin-dispatch--active nil))
    (cl-letf (((symbol-function 'maduin-cockpit--seats)
               (lambda () '(("broken" . "implementer"))))
              ((symbol-function 'maduin-config-seat-backend)
               (lambda (&rest _args) (error "malformed config"))))
      (let ((status (maduin-cockpit--seat-status "broken")))
        (should-not (plist-get status :model))
        (should-not (plist-get status :backend))))))

(ert-deftest maduin-test-cockpit-active-model-remains-launch-model ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config))
        (maduin-dispatch--active
         (list (list :handle "s-1" :seat "ifrit" :role 'implementer
                     :model "launch-model" :backend 'opencode))))
    (maduin-config-set-crew-backend 'kiro)
    (let* ((status (maduin-cockpit--seat-status "ifrit"))
           (row (assoc "ifrit" (maduin-cockpit--rows))))
      (should (eq (plist-get status :backend) 'opencode))
      (should (equal (plist-get status :model) "launch-model"))
      (should (equal (aref (cadr row) 4) "launch-model")))))

(ert-deftest maduin-test-cockpit-title-pure-read ()
  :tags '(maduin)
  (let ((maduin-state--data nil)
        (maduin-cockpit--title-queue nil)
        (maduin-cockpit--title-requested (make-hash-table :test #'equal))
        (maduin-dispatch--active
         (list (list :handle "s-1" :seat "ifrit" :role 'implementer :task "maduin-x"))))
    (cl-letf (((symbol-function 'call-process) (lambda (&rest _) (error "spawned")))
              ((symbol-function 'make-process) (lambda (&rest _) (error "spawned")))
              ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
      (let* ((rows (maduin-cockpit--rows))
             (row (assoc "ifrit" rows))
             (task (aref (cadr row) 3)))
        (should (string-match-p "maduin-x" task))
        (should-not (string-match-p " — " task))))))

(ert-deftest maduin-test-cockpit-title-async-resolves ()
  :tags '(maduin)
  (let ((maduin-state--data nil)
        (maduin-cockpit--title-queue nil)
        (maduin-cockpit--title-requested (make-hash-table :test #'equal))
        (maduin-dispatch--active
         (list (list :handle "s-1" :seat "ifrit" :role 'implementer :task "maduin-x")))
        (refreshes 0))
    (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
              ((symbol-function 'maduin-bd-async-call)
               (lambda (_args callback)
                 (funcall callback 0 "[{\"title\":\"Big Title\"}]")
                 "title-request"))
              ((symbol-function 'maduin-cockpit--schedule-refresh)
               (lambda () (cl-incf refreshes))))
      (should-not (plist-get (maduin-cockpit--seat-status "ifrit") :task-title))
      (maduin-cockpit--title-drain)
      (should (equal (maduin-cockpit--title "maduin-x") "Big Title"))
      (should (= refreshes 1))
      (should (string-match-p "maduin-x — Big Title"
                              (maduin-cockpit--task-string
                               (maduin-cockpit--seat-status "ifrit")))))))

(ert-deftest maduin-test-cockpit-title-bare-object-shape ()
  :tags '(maduin)
  (let ((maduin-state--data nil)
        (maduin-cockpit--title-queue nil)
        (maduin-cockpit--title-requested (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
              ((symbol-function 'maduin-bd-async-call)
               (lambda (_args callback)
                 (funcall callback 0 "{\"title\":\"Obj Title\"}")
                 "title-request"))
              ((symbol-function 'maduin-cockpit--schedule-refresh) #'ignore))
      (maduin-cockpit--title-request "maduin-z")
      (maduin-cockpit--title-drain)
      (should (equal (maduin-cockpit--title "maduin-z") "Obj Title")))))

(ert-deftest maduin-test-cockpit-title-negative-cache ()
  :tags '(maduin)
  (let ((maduin-state--data nil)
        (maduin-cockpit--title-queue nil)
        (maduin-cockpit--title-requested (make-hash-table :test #'equal))
        (maduin-cockpit-title-negative-ttl 60.0)
        (now 100.0)
        (requests 0))
    (cl-letf (((symbol-function 'float-time) (lambda (&optional _) now))
              ((symbol-function 'run-at-time) (lambda (&rest _) nil))
              ((symbol-function 'maduin-bd-async-call)
               (lambda (_args callback)
                 (cl-incf requests)
                 (funcall callback 1 "failed")
                 "title-request"))
              ((symbol-function 'maduin-cockpit--schedule-refresh) #'ignore))
      (dotimes (_ 5)
        (maduin-cockpit--title-request "maduin-y")
        (maduin-cockpit--title-drain))
      (should (= requests 1))
      (setq now 161.0)
      (maduin-cockpit--title-request "maduin-y")
      (maduin-cockpit--title-drain)
      (should (= requests 2)))))

(ert-deftest maduin-test-cockpit-title-invalidated-on-complete ()
  :tags '(maduin)
  (let ((maduin-state--data nil)
        (maduin-cockpit-refresh-hook nil))
    (maduin-cockpit--title-put "maduin-x" "Big Title")
    (should (hash-table-p (maduin-state-get 'titles)))
    (maduin-cockpit--on-complete "s-1" 'completed)
    (should-not (maduin-state-get 'titles))))

(ert-deftest maduin-test-cockpit-status-pill-known ()
  :tags '(maduin)
  (dolist (s '(dead idle working running repairing))
    (let ((pill (maduin-cockpit--status-pill s)))
      (should (string= pill (symbol-name s)))
      (should (eq (get-text-property 0 'face pill)
                  (maduin-cockpit-state-face s))))))

(ert-deftest maduin-test-cockpit-status-pill-unknown ()
  :tags '(maduin)
  (let ((pill (maduin-cockpit--status-pill 'mystery)))
    (should (string= pill "mystery"))
    (should (null (get-text-property 0 'face pill))))
  (let ((pill (maduin-cockpit--status-pill nil)))
    (should (string= pill "dead"))
    (should (null (get-text-property 0 'face pill)))))

(ert-deftest maduin-test-cockpit-pipeline-summary-chips ()
  :tags '(maduin)
  (let ((summary (maduin-cockpit--pipeline-summary)))
    (dolist (k '(queued active completed blocked fleet-free fleet-busy))
      (should (string-match-p (symbol-name k) summary))
      (let ((pos (string-match (symbol-name k) summary)))
        (should (facep (get-text-property pos 'face summary)))))))

(ert-deftest maduin-test-cockpit-refresh-format-8-columns ()
  :tags '(maduin)
  (let ((buf (get-buffer-create "*maduin-cockpit*"))
        (maduin-state--data nil))
    (unwind-protect
        (with-current-buffer buf
          (tabulated-list-mode)
          (maduin-cockpit--title-put "stale" "old")
          (maduin-cockpit-refresh)
          (should (= (length tabulated-list-format) 8))
          (should (equal (elt (aref tabulated-list-format 0) 0) "Seat"))
          (should (equal (elt (aref tabulated-list-format 1) 0) "Role"))
          (should (equal (elt (aref tabulated-list-format 2) 0) "Status"))
          (should (equal (elt (aref tabulated-list-format 3) 0) "Task"))
          (should (equal (elt (aref tabulated-list-format 4) 0) "Model"))
          (should (equal (elt (aref tabulated-list-format 5) 0) "Backend"))
          (should (equal (elt (aref tabulated-list-format 6) 0) "Uptime"))
          (should (equal (elt (aref tabulated-list-format 7) 0) "Activity"))
          (should (equal (maduin-cockpit--title "stale") "old")))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-refresh-keeps-title-cache ()
  :tags '(maduin)
  (let ((buf (get-buffer-create "*maduin-cockpit*"))
        (calls 0)
        (maduin-state--data nil)
        (maduin-dispatch--active
         (list (list :handle "s-1" :seat "ifrit" :role "implementer" :task "t1")
               (list :handle "s-2" :seat "shiva" :role "designer" :task "t2"))))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-bd-async-call)
                   (lambda (&rest _) (cl-incf calls)))
                  ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
          (maduin-cockpit--title-put "t1" "T1")
          (maduin-cockpit--title-put "t2" "T2")
          (with-current-buffer buf (tabulated-list-mode))
          (maduin-cockpit-refresh)
          (maduin-cockpit-refresh)
          (maduin-cockpit-refresh)
          (should (= calls 0))
          (should (= (hash-table-count (maduin-state-get 'titles)) 2)))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-live-derived-uptime-phase-and-status ()
  :tags '(maduin)
  (let ((maduin-dispatch--active
         (list (list :seat "ifrit" :role 'implementer :status 'repairing
                     :phase "tool" :started 100.0))))
    (cl-letf (((symbol-function 'float-time) (lambda () 347.0)))
      (let ((status (maduin-cockpit--seat-status "ifrit")))
        (should (= (plist-get status :uptime) 247.0))
        (should (equal (maduin-cockpit--uptime-string status) "04:07"))
        (should (equal (plist-get status :phase) "tool"))
        (should (equal (maduin-cockpit--status-pill
                        (plist-get status :status)) "repairing")))))
  (should (equal (maduin-cockpit--uptime-string '(:uptime 3847))
                 "01:04:07"))
  (should (equal (maduin-cockpit--uptime-string '(:uptime nil)) "—")))

(ert-deftest maduin-test-cockpit-live-header-holds-chips-not-body ()
  :tags '(maduin)
  (let ((buf (generate-new-buffer " *maduin-cockpit-live-header*"))
        (maduin-dispatch--active nil)
        (maduin-dispatch--timer nil)
        (maduin-dispatch--draining nil))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-cockpit--seats)
                   (lambda () '(("alexander" . "concierge"))))
                  ((symbol-function 'maduin-pipeline-status)
                   (lambda () '(:queued 2 :active 1 :completed 3 :blocked 4
                                :fleet-free 5 :fleet-busy 6))))
          (with-current-buffer buf
            (tabulated-list-mode)
            (maduin-cockpit-refresh)
            (should (equal header-line-format
                           '((:eval maduin-cockpit--header-cache))))
            (should (string-match-p "maduin 0.3.0 · stopped" 
                                    maduin-cockpit--header-cache))
            (should (string-match-p "queued 2" maduin-cockpit--header-cache))
            (should-not (string-match-p "queued 2" (buffer-string)))))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-live-header-run-state ()
  :tags '(maduin)
  (let ((timer (run-at-time 60 nil #'ignore)))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-pipeline-status)
                   (lambda () '(:queued 0 :active 0 :completed 0 :blocked 0
                                :fleet-free 0 :fleet-busy 0))))
          (let ((maduin-dispatch--timer timer)
                (maduin-dispatch--draining nil))
            (should (string-match-p " · running ·"
                                    (maduin-cockpit--header-string))))
          (let ((maduin-dispatch--timer nil)
                (maduin-dispatch--draining t))
            (should (string-match-p " · draining ·"
                                    (maduin-cockpit--header-string)))))
      (cancel-timer timer))))

(ert-deftest maduin-test-cockpit-refresh-preserves-point-and-window-start ()
  :tags '(maduin)
  (let* ((buf (generate-new-buffer " *maduin-cockpit-live-refresh*"))
         (window (selected-window))
         (original (window-buffer window))
         (maduin-dispatch--active nil))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-cockpit--seats)
                   (lambda () '(("alexander" . "concierge")
                                ("ramuh" . "designer")
                                ("ifrit" . "implementer"))))
                  ((symbol-function 'maduin-pipeline-status)
                   (lambda () '(:queued 0 :active 0 :completed 0 :blocked 0
                                :fleet-free 0 :fleet-busy 0))))
          (set-window-buffer window buf)
          (with-current-buffer buf
            (tabulated-list-mode)
            (maduin-cockpit-refresh)
            (goto-char (point-min))
            (search-forward "ifrit")
            (setq tabulated-list-sort-key '("Role" . nil))
            (let ((point-before (point))
                  (start-before (window-start window)))
              (maduin-cockpit-refresh)
              (maduin-cockpit-refresh)
              (should (= (point) point-before))
              (should (equal tabulated-list-sort-key '("Role" . nil)))
              (should (= (window-start window) start-before)))))
      (set-window-buffer window original)
      (kill-buffer buf))))

;;; 8d. cockpit-live

(ert-deftest maduin-test-cockpit-live-refresh-hook-defined ()
  :tags '(maduin)
  (should (boundp 'maduin-cockpit-refresh-hook))
  (should (listp maduin-cockpit-refresh-hook)))

(ert-deftest maduin-test-cockpit-live-register-once ()
  :tags '(maduin)
  (maduin-cockpit--register-live-updates)
  (maduin-cockpit--register-live-updates)
  (should (memq #'maduin-cockpit--schedule-refresh maduin-cockpit-refresh-hook))
  (should (memq #'maduin-cockpit--on-complete maduin-session-on-complete-hook))
  (should (= (cl-count #'maduin-cockpit--schedule-refresh
                       maduin-cockpit-refresh-hook)
             1))
  (should (= (cl-count #'maduin-cockpit--on-complete
                       maduin-session-on-complete-hook)
             1)))

(ert-deftest maduin-test-cockpit-live-on-complete-runs-hook ()
  :tags '(maduin)
  (let* ((count 0)
         (maduin-state--data nil)
         (maduin-cockpit-refresh-hook (list (lambda () (setq count (1+ count))))))
    (maduin-cockpit--title-put "t1" "Old Title")
    (maduin-cockpit--on-complete "s-1" 'completed)
    (should (= count 1))
    (should-not (maduin-state-get 'titles))))

(ert-deftest maduin-test-dispatch-spawn-runs-cockpit-refresh-hook ()
  :tags '(maduin)
  ;; Spawn path nudge: dispatch fires the guarded refresh hook, no require.
  (let* ((dir (maduin-test--temp-dir))
         (count 0)
         (maduin-cockpit-refresh-hook (list (lambda () (setq count (1+ count)))))
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p _b &optional _effort) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir)))
    (unwind-protect
        (progn
          (should (equal (maduin-dispatch-implement "t1") "s-1"))
          (should (= count 1)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-on-complete-runs-cockpit-refresh-hook ()
  :tags '(maduin)
  ;; Removal and routed-completion transitions each nudge the cockpit.
  (let* ((dir (maduin-test--temp-dir))
         (count 0)
         (maduin-cockpit-refresh-hook (list (lambda () (setq count (1+ count)))))
         (maduin-dispatch--active
          (list (list :handle "s-1" :seat "ifrit" :role 'implementer :task "t1")))
         (maduin-dispatch--diff-fn (lambda (_backend _sid) nil))
         (maduin-dispatch--land-fn (lambda (_seat &optional _stamp) t))
         (maduin-dispatch--close-fn (lambda (_t _o &optional _dir) t))
         (maduin-dispatch--session-delete-fn (lambda (_backend _sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch--on-complete "s-1" 'completed)
          (should (= count 2))
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))


;;; 8d. dispatch-live-state

(ert-deftest maduin-test-dispatch-live-spawn-entry-state ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (count 0)
         (maduin-cockpit-refresh-hook (list (lambda () (cl-incf count))))
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p _b &optional _effort) "live-1"))
         (maduin-dispatch--claim-fn (lambda (_task) t))
         (maduin-dispatch--show-fn (lambda (_task) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_seat) dir)))
    (unwind-protect
        (let ((entry (progn
                       (should (equal (maduin-dispatch-implement "t-live") "live-1"))
                       (car maduin-dispatch--active))))
          (should (floatp (plist-get entry :started)))
          (should (eq (plist-get entry :status) 'working))
          (should (= count 1)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-live-event-updates-phase-and-status ()
  :tags '(maduin)
  (let* ((count 0)
         (maduin-cockpit-refresh-hook (list (lambda () (cl-incf count))))
         (maduin-dispatch--active
          (list (list :handle "live-1" :seat "ifrit" :role 'implementer
                      :task "t-live" :status 'working))))
    (should-not (maduin-dispatch--on-event "live-1" "thinking"))
    (let ((entry (car maduin-dispatch--active)))
      (should (equal (plist-get entry :phase) "thinking"))
      (should (eq (plist-get entry :status) 'running)))
    (should (= count 1))
    (maduin-dispatch--on-event "live-1" "tool")
    (should (equal (plist-get (car maduin-dispatch--active) :phase) "tool"))
    (should (= count 2))))

(ert-deftest maduin-test-dispatch-live-notify-unbound-noop ()
  :tags '(maduin)
  (let ((was-bound (boundp 'maduin-cockpit-refresh-hook))
        (saved (and (boundp 'maduin-cockpit-refresh-hook)
                    (symbol-value 'maduin-cockpit-refresh-hook))))
    (unwind-protect
        (progn
          (makunbound 'maduin-cockpit-refresh-hook)
          (should-not (maduin-dispatch--notify)))
      (when was-bound
        (set 'maduin-cockpit-refresh-hook saved)))))

(ert-deftest maduin-test-dispatch-live-event-hook-registers-once ()
  :tags '(maduin)
  (let ((was-bound (boundp 'maduin-session-on-event-hook))
        (saved (and (boundp 'maduin-session-on-event-hook)
                    (symbol-value 'maduin-session-on-event-hook))))
    (unwind-protect
        (progn
          (funcall #'set 'maduin-session-on-event-hook nil)
          (maduin-dispatch--register-event-hook)
          (maduin-dispatch--register-event-hook)
          (should (memq #'maduin-dispatch--on-event
                        (symbol-value 'maduin-session-on-event-hook)))
          (should (= (cl-count #'maduin-dispatch--on-event
                               (symbol-value 'maduin-session-on-event-hook))
                     1)))
      (if was-bound
          (funcall #'set 'maduin-session-on-event-hook saved)
        (makunbound 'maduin-session-on-event-hook)))))

(ert-deftest maduin-test-dispatch-live-old-entries-keep-concurrency-accounting ()
  :tags '(maduin)
  (let ((maduin-dispatch--active
         (list (list :handle "old-1" :seat "ifrit" :role 'implementer :task "t1")
               (list :handle "old-2" :seat "shiva" :role 'implementer :task "t2"))))
    (should (= (maduin-dispatch--active-role-count 'implementer) 2))
    (should (equal (maduin-dispatch--free-seat 'implementer) "titan"))))
;;; 8e. cockpit-inbox (embedded chaplet inbox)

(ert-deftest maduin-test-cockpit-show-inbox-absent-still-renders ()
  :tags '(maduin)
  ;; chaplet absent → cockpit still renders, message issued, no error.
  (let ((msg nil))
    (unwind-protect
        (cl-letf (((symbol-function 'require)
                   (lambda (_feature &optional _na _ne) nil))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (setq msg (apply #'format fmt args)))))
          (should (bufferp (maduin-cockpit-show)))
          (should (get-buffer "*maduin-cockpit*"))
          (should (string-match-p "chaplet" msg)))
      (when (get-buffer "*maduin-cockpit*")
        (kill-buffer "*maduin-cockpit*")))))

(ert-deftest maduin-test-cockpit-inbox-embed-absent-noop ()
  :tags '(maduin)
  ;; chaplet not loadable → nil + message, never an error.
  (let ((msg nil))
    (cl-letf (((symbol-function 'require)
               (lambda (_feature &optional _na _ne) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq msg (apply #'format fmt args)))))
      (should-not (maduin-cockpit--embed-inbox)))
    (should (string-match-p "chaplet" msg))))

(ert-deftest maduin-test-cockpit-inbox-embed-present ()
  :tags '(maduin)
  ;; chaplet available (mocked) → lower window returned, view set inbox,
  ;; cockpit buffer stays in the main (selected) window.
  (let ((view nil)
        (buf (get-buffer-create "*maduin-cockpit*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (let ((main (selected-window)))
            (cl-letf (((symbol-function 'require)
                       (lambda (_feature &optional _na _ne) t))
                      ((symbol-function 'chaplet-list-set-view)
                       (lambda (name) (setq view name))))
              (let ((win (maduin-cockpit--embed-inbox)))
                (unwind-protect
                    (progn
                      (should (windowp win))
                      (should (eq view 'inbox))
                      (should (eq (selected-window) main))
                      (should (eq (window-buffer main) buf))
                      (should-not (eq win main)))
                  (when (and win (windowp win) (window-live-p win))
                    (ignore-errors (delete-window win))))))))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-inbox-refresh-noop-no-buffer ()
  :tags '(maduin)
  ;; Inbox buffer absent → refresh fn never invoked, silent no-op.
  (when (get-buffer "*chaplet*") (kill-buffer "*chaplet*"))
  (let ((called nil))
    (cl-letf (((symbol-function 'chaplet-list-refresh)
               (lambda () (setq called t))))
      (should-not (maduin-cockpit--inbox-refresh))
      (should-not called))))

(ert-deftest maduin-test-cockpit-inbox-refresh-refreshes-when-present ()
  :tags '(maduin)
  ;; Inbox buffer live in chaplet-list-mode → refresh invoked once.
  (let ((buf (get-buffer-create "*chaplet*"))
        (called nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq major-mode 'chaplet-list-mode))
          (cl-letf (((symbol-function 'chaplet-list-refresh)
                     (lambda () (setq called t))))
            (should (maduin-cockpit--inbox-refresh))
            (should called)))
      (kill-buffer buf))))

;;; 8f. cockpit-evil (evil-aware keybindings + inbox jump)

(ert-deftest maduin-test-cockpit-evil-symbols-exist ()
  :tags '(maduin)
  (should (fboundp 'maduin-cockpit--bind))
  (should (fboundp 'maduin-cockpit--evil-setup))
  (should (commandp 'maduin-cockpit-inbox)))

(ert-deftest maduin-test-cockpit-evil-plain-map-bindings ()
  :tags '(maduin)
  ;; Plain map carries r/q/i via the single-source-of-truth helper.
  (should (eq (lookup-key maduin-cockpit-map (kbd "r"))
              'maduin-cockpit-refresh))
  (should (eq (lookup-key maduin-cockpit-map (kbd "q"))
              'quit-window))
  (should (eq (lookup-key maduin-cockpit-map (kbd "i"))
              'maduin-cockpit-inbox))
  ;; Attach/kill removed: RET and k are unbound in the plain map.
  (should-not (lookup-key maduin-cockpit-map (kbd "RET")))
  (should-not (lookup-key maduin-cockpit-map (kbd "k")))
  ;; Leak suppression is evil-only: plain map must NOT bind "v".
  (should-not (lookup-key maduin-cockpit-map (kbd "v"))))

(ert-deftest maduin-test-cockpit-evil-setup-mirrors-normal-motion ()
  :tags '(maduin)
  ;; featurep+mock recorder: normal/motion receive the shared bindings AND
  ;; the leak keys (v etc.) bound to nil.
  (let ((recorded nil))
    (cl-letf (((symbol-function 'featurep)
               (lambda (f &optional _sub) (eq f 'evil)))
              ((symbol-function 'fboundp)
               (lambda (f) (eq f 'evil-define-key*)))
              ((symbol-function 'evil-define-key*)
               (lambda (state _map key def)
                 (push (list state key def) recorded))))
      (maduin-cockpit--evil-setup)
      (dolist (binding maduin-cockpit--bindings)
        (let ((key (kbd (car binding))) (def (cdr binding)))
          (should (member (list 'normal key def) recorded))
          (should (member (list 'motion key def) recorded))))
      ;; v (and every suppress key) → nil in BOTH evil states.
      (should (member (list 'normal (kbd "v") nil) recorded))
      (should (member (list 'motion (kbd "v") nil) recorded))
      (dolist (key maduin-cockpit--evil-suppress-keys)
        (should (member (list 'normal (kbd key) nil) recorded))
        (should (member (list 'motion (kbd key) nil) recorded))))))

(ert-deftest maduin-test-cockpit-evil-setup-no-evil-noop ()
  :tags '(maduin)
  ;; evil absent → guard short-circuits, evil-define-key* never called.
  (let ((calls 0))
    (cl-letf (((symbol-function 'featurep) (lambda (_f &optional _s) nil))
              ((symbol-function 'evil-define-key*)
               (lambda (&rest _) (cl-incf calls))))
      (maduin-cockpit--evil-setup)
      (should (= calls 0)))))

(ert-deftest maduin-test-cockpit-inbox-selects-window ()
  :tags '(maduin)
  ;; Inbox window live → select-window invoked on it.
  (let ((win (selected-window))
        (selected nil))
    (cl-letf (((symbol-function 'get-buffer-window)
               (lambda (_buf &optional _f) win))
              ((symbol-function 'select-window)
               (lambda (w) (setq selected w))))
      (maduin-cockpit-inbox)
      (should (eq selected win)))))

(ert-deftest maduin-test-cockpit-inbox-absent-message ()
  :tags '(maduin)
  ;; Inbox absent → polite message, no error, no selection.
  (let ((msg nil))
    (cl-letf (((symbol-function 'get-buffer-window)
               (lambda (_buf &optional _f) nil))
              ((symbol-function 'select-window)
               (lambda (_w) (error "must not select")))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq msg (apply #'format fmt args)))))
      (maduin-cockpit-inbox)
      (should (string-match-p "no inbox" msg)))))

;;; 9. main

(ert-deftest maduin-test-main-commands-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-mode
               maduin-start
               maduin-stop
               maduin-status
               maduin-restart
                maduin-concierge
                maduin-concierge-dismiss
                maduin-bootstrap))
    (should (fboundp f))))

;;; 10. workspace integration

(ert-deftest maduin-test-workspace-path ()
  :tags '(maduin)
  (should (equal (maduin-workspace-path "alexander")
                 (expand-file-name
                  "alexander"
                  (expand-file-name
                   (or (cdr (assq 'path (cdr (assq 'workspaces maduin-config))))
                       "harness/workspaces")
                   (maduin-project-root))))))

(ert-deftest maduin-test-workspace-exists-bogus ()
  :tags '(maduin)
  (should-not (maduin-workspace-exists-p "no-such-seat-xyz")))

(ert-deftest maduin-test-workspace-ensure-real-worktree ()
  :tags '(maduin)
  (let ((seat "maduin-ws-probe")
        (wt nil))
    (unwind-protect
        (progn
          (setq wt (maduin-workspace-ensure seat))
          (should wt)
          (should (file-directory-p wt))
          (should (maduin-workspace-exists-p seat))
          (should (maduin-bd-worktree-real-p wt))
          ;; `git -C WT rev-parse --show-toplevel' must resolve INSIDE the
          ;; worktree (not the main repo), proving it is a real git worktree.
          (let ((top (string-trim
                      (with-temp-buffer
                        (call-process shell-file-name nil t nil
                                      shell-command-switch
                                      (format "git -C %s rev-parse --show-toplevel"
                                              (shell-quote-argument wt)))
                        (buffer-string)))))
            (should (string= (directory-file-name (file-truename top))
                             (directory-file-name (file-truename wt))))))
      ;; Cleanup: remove the worktree registration and its branch.
      (ignore-errors
        (when (and wt (maduin-bd-worktree-real-p wt))
          (call-process shell-file-name nil nil nil shell-command-switch
                        (format "git worktree remove --force %s"
                                (shell-quote-argument wt)))
          (call-process shell-file-name nil nil nil shell-command-switch
                        (format "git branch -D %s"
                                (shell-quote-argument seat))))))))

(ert-deftest maduin-test-workspace-cleanup-removes-real-worktree ()
  :tags '(maduin)
  ;; Scratch repo: git init + seed commit off the harness dir, then a REAL
  ;; worktree + branch, all under a temp dir.  Seams point cleanup at the
  ;; scratch repo; after cleanup the worktree is unregistered and the branch
  ;; is gone.  Never touches the real main repo.
  (let* ((dir (maduin-test--temp-dir))
         (wt (expand-file-name "wt" dir))
         (branch "cleanup-branch-xyz")
         (result nil)
         (maduin-workspace--main-root-fn (lambda () dir)))
    (unwind-protect
        (progn
          (maduin-workspace--git dir "init" "-q")
          (maduin-workspace--git dir "config" "user.email" "t@example.com")
          (maduin-workspace--git dir "config" "user.name" "Test")
          (write-region "seed\n" nil (expand-file-name "seed.txt" dir))
          (maduin-workspace--git dir "add" "-A")
          (maduin-workspace--git dir "commit" "-q" "-m" "seed")
          (maduin-workspace--git dir "worktree" "add" wt "-b" branch)
          (should (maduin-bd-worktree-real-p wt))
          (cl-letf (((symbol-function 'maduin-workspace-path) (lambda (_s) wt))
                    ((symbol-function 'maduin-workspace-branch) (lambda (_s) branch)))
            (setq result (maduin-workspace-cleanup "test-seat")))
          (should (eq result t))
          (should-not (maduin-bd-worktree-real-p wt))
          (should (/= 0 (car (maduin-workspace--git-output
                              dir "rev-parse" "--verify" branch)))))
      (ignore-errors (delete-directory wt t))
      (ignore-errors (maduin-workspace--git dir "worktree" "prune"))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest maduin-test-workspace-cleanup-missing-worktree ()
  :tags '(maduin)
  ;; Worktree dir missing → t immediately, no git calls at all.
  (let* ((dir (maduin-test--temp-dir))
         (maduin-workspace--main-root-fn (lambda () dir))
         (maduin-workspace--git-fn (lambda (&rest _) (error "git-fn must not run")))
         (maduin-workspace--git-output-fn
          (lambda (&rest _) (error "git-output-fn must not run"))))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-workspace-path)
                   (lambda (_s) (expand-file-name "no-such-wt" dir)))
                  ((symbol-function 'maduin-workspace-branch)
                   (lambda (_s) "missing-branch-xyz")))
          (should (eq (maduin-workspace-cleanup "test-seat") t)))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest maduin-test-workspace-cleanup-remove-failure ()
  :tags '(maduin)
  ;; Branch verifies, but `git worktree remove' fails → nil + warning,
  ;; tree left (no delete-directory fallback).
  (let* ((dir (maduin-test--temp-dir))
         (wt (expand-file-name "wt" dir))
         (logged nil)
         (maduin-workspace--main-root-fn (lambda () dir))
         (maduin-workspace--git-fn
          (lambda (_d &rest args) (if (member "remove" args) 1 0)))
         (maduin-workspace--git-output-fn
          (lambda (_d &rest _args) (cons 0 "abc123\n"))))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-workspace-path) (lambda (_s) wt))
                  ((symbol-function 'maduin-workspace-branch)
                   (lambda (_s) "cleanup-branch-xyz"))
                  ((symbol-function 'maduin-workspace--log-warning)
                   (lambda (msg) (setq logged msg))))
          (make-directory wt t)
          (should (null (maduin-workspace-cleanup "test-seat")))
          (should (stringp logged))
          (should (file-directory-p wt)))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest maduin-test-workspace-cleanup-missing-branch ()
  :tags '(maduin)
  ;; Worktree exists but branch no longer verifies → t without branch -D.
  ;; git-fn errors on any "-D" call; reaching it would flip the result to nil.
  (let* ((dir (maduin-test--temp-dir))
         (wt (expand-file-name "wt" dir))
         (maduin-workspace--main-root-fn (lambda () dir))
         (maduin-workspace--git-fn
          (lambda (_d &rest args)
            (when (member "-D" args) (error "branch -D must not run"))
            0))
         (maduin-workspace--git-output-fn
          (lambda (_d &rest _args) (cons 128 "fatal: needed a single revision\n"))))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-workspace-path) (lambda (_s) wt))
                  ((symbol-function 'maduin-workspace-branch)
                   (lambda (_s) "ghost-branch-xyz")))
          (make-directory wt t)
          (should (eq (maduin-workspace-cleanup "test-seat") t)))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest maduin-test-bootstrap-no-error ()
  :tags '(maduin)
  (condition-case err
      (progn
        (maduin-bootstrap)
        (should t))
    (error
     (ert-fail (format "bootstrap errored: %s" (error-message-string err))))))

(ert-deftest maduin-test-land-branch-bogus-seat ()
  :tags '(maduin)
  (condition-case err
      (should (null (maduin-pipeline-land-branch "no-such-seat-xyz")))
    (error
     (ert-fail (format "land-branch errored: %s" (error-message-string err))))))

(ert-deftest maduin-test-land-branch-success ()
  :tags '(maduin)
  ;; Commit → verify branch → rebase onto main → fast-forward main.  Rebase
  ;; of a branch already containing main is a no-op that still exits 0, so
  ;; this subsumes the old `merge-base --is-ancestor' shortcut.
  (let* ((calls nil)
         (maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
         (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
         (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
         (maduin-pipeline--git-fn
          (lambda (_dir &rest args) (push args calls) 0))
         (maduin-pipeline--git-output-fn
          (lambda (_dir &rest args)
            (push args calls)
           (cond
            ((member "commit" args) (cons 0 ""))
            ((member "rev-parse" args) (cons 0 "abc123\n"))
            ((member "rebase" args) (cons 0 ""))
            ((member "merge" args) (cons 0 ""))))))
    (should (eq (maduin-pipeline-land-branch "test-seat") t))
    ;; Both the rebase and the ff-only merge must run, with exact args.
    (should (cl-some (lambda (a)
                       (equal a '("rebase" "main" "seat-branch-xyz")))
                     calls))
    (should (cl-some (lambda (a)
                       (equal a '("merge" "--ff-only" "seat-branch-xyz")))
                     calls))))

(ert-deftest maduin-test-land-branch-nothing-to-commit-still-merges ()
  :tags '(maduin)
  ;; Worker pre-committed → `git commit' reports "nothing to commit" (exit
  ;; 1), but the branch still gets rebased onto main and fast-forwarded,
  ;; returning t on success.
  (let ((maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
        (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
        (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
        (maduin-pipeline--git-fn (lambda (_dir &rest _args) 0))
        (maduin-pipeline--git-output-fn
         (lambda (_dir &rest args)
           (cond
            ((member "commit" args)
             (cons 1 "nothing to commit, working tree clean\n"))
            ((member "rev-parse" args) (cons 0 "abc123\n"))
            ((member "rebase" args) (cons 0 ""))
            ((member "merge" args) (cons 0 ""))))))
    (should (eq (maduin-pipeline-land-branch "test-seat") t))))

(ert-deftest maduin-test-land-branch-rebase-conflict ()
  :tags '(maduin)
  ;; Commit succeeds (or nothing to commit) → branch verifies → rebase
  ;; reports a conflict → abort the failed rebase in main (leaving the
  ;; branch at its pre-rebase state, no jammed rebase) → returns `conflict'.
  (let* ((calls nil)
         (maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
         (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
         (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
         (maduin-pipeline--git-fn
          (lambda (_dir &rest args) (push args calls) 0))
         (maduin-pipeline--git-output-fn
          (lambda (_dir &rest args)
            (cond
             ((member "commit" args) (cons 0 ""))
             ((member "rev-parse" args) (cons 0 "abc123\n"))
             ((member "rebase" args)
              (cons 1 "CONFLICT (content): Merge conflict in foo.el\n"))))))
    (should (eq (maduin-pipeline-land-branch "test-seat") 'conflict))
    ;; The failed rebase must be aborted so the branch isn't left mid-rebase.
    (should (cl-some (lambda (args) (equal args '("rebase" "--abort"))) calls))))

(ert-deftest maduin-test-land-branch-rebase-failure ()
  :tags '(maduin)
  ;; Rebase fails for a non-conflict reason (e.g. a git error) → log a
  ;; warning naming the branch → return nil.
  (let ((logged nil)
        (maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
        (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
        (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
        (maduin-pipeline--git-fn (lambda (_dir &rest _args) 0))
        (maduin-pipeline--git-output-fn
         (lambda (_dir &rest args)
           (cond
            ((member "commit" args) (cons 0 ""))
            ((member "rev-parse" args) (cons 0 "abc123\n"))
            ((member "rebase" args)
             (cons 128 "fatal: update_ref failed\n"))))))
    (cl-letf (((symbol-function 'maduin-workspace--log-warning)
               (lambda (msg) (setq logged msg))))
      (should (null (maduin-pipeline-land-branch "test-seat")))
      (should (stringp logged))
      (should (string-match-p "rebase" logged)))))

(ert-deftest maduin-test-land-branch-ff-only-fail ()
  :tags '(maduin)
  ;; Rebase ok, but the fast-forward merge fails (e.g. main moved
  ;; concurrently) → log a warning naming the branch → return nil.
  (let ((logged nil)
        (maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
        (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
        (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
        (maduin-pipeline--git-fn (lambda (_dir &rest _args) 0))
        (maduin-pipeline--git-output-fn
         (lambda (_dir &rest args)
           (cond
            ((member "commit" args) (cons 0 ""))
            ((member "rev-parse" args) (cons 0 "abc123\n"))
            ((member "rebase" args) (cons 0 ""))
            ((member "merge" args)
             (cons 1 "fatal: Not possible to fast-forward, aborting.\n"))))))
    (cl-letf (((symbol-function 'maduin-workspace--log-warning)
               (lambda (msg) (setq logged msg))))
      (should (null (maduin-pipeline-land-branch "test-seat")))
      (should (stringp logged))
      (should (string-match-p "ff-only" logged)))))

(ert-deftest maduin-test-land-branch-missing-branch ()
  :tags '(maduin)
  ;; Commit done (or nothing to commit), but the seat branch does not exist
  ;; → logs a warning naming the branch and returns nil (never rebases).
  (let ((logged nil)
        (maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
        (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
        (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
        (maduin-pipeline--git-fn (lambda (_dir &rest _args) 0))
        (maduin-pipeline--git-output-fn
         (lambda (_dir &rest args)
           (cond
            ((member "commit" args) (cons 0 ""))
            ((member "rev-parse" args)
             (cons 128 "fatal: needed a single revision\n"))))))
    (cl-letf (((symbol-function 'maduin-workspace--log-warning)
               (lambda (msg) (setq logged msg))))
      (should (null (maduin-pipeline-land-branch "test-seat")))
      (should (stringp logged))
      (should (string-match-p "seat-branch-xyz" logged)))))

(ert-deftest maduin-test-pipeline-land-nil-stamp-argv-unchanged ()
  :tags '(maduin)
  (let* ((calls nil)
         (maduin-pipeline--worktree-path-fn (lambda (_seat) maduin-test--dir))
         (maduin-pipeline--branch-fn (lambda (_seat) "seat-branch-xyz"))
         (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
         (maduin-pipeline--git-fn (lambda (_dir &rest args) (push args calls) 0))
         (maduin-pipeline--git-output-fn
          (lambda (_dir &rest args)
            (push args calls)
            (cond
             ((member "commit" args) (cons 0 ""))
             ((member "rev-parse" args) (cons 0 "abc123\n"))
             ((member "rebase" args) (cons 0 ""))
             ((member "merge" args) (cons 0 ""))))))
    (should (eq (maduin-pipeline-land-branch "ifrit") t))
    (should (member '("rebase" "main" "seat-branch-xyz") calls))
    (should-not (cl-some (lambda (args) (member "--exec" args)) calls))))

(ert-deftest maduin-test-pipeline-land-stamped-rebase-has-exec ()
  :tags '(maduin)
  (let* ((calls nil)
         (stamp '(:model "gpt-5.6-terra" :backend kiro :seat "ifrit"))
         (maduin-pipeline--worktree-path-fn (lambda (_seat) maduin-test--dir))
         (maduin-pipeline--branch-fn (lambda (_seat) "seat-branch-xyz"))
         (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
         (maduin-pipeline--git-fn (lambda (_dir &rest args) (push args calls) 0))
         (maduin-pipeline--git-output-fn
          (lambda (_dir &rest args)
            (push args calls)
            (cond
             ((member "commit" args) (cons 0 ""))
             ((member "rev-parse" args) (cons 0 "abc123\n"))
             ((member "rebase" args) (cons 0 ""))
             ((member "merge" args) (cons 0 ""))))))
    (should (eq (maduin-pipeline-land-branch "ifrit" stamp) t))
    (let* ((rebase (cl-find-if (lambda (args) (member "--exec" args)) calls))
           (exec-index (cl-position "--exec" rebase :test #'equal))
           (command (nth (1+ exec-index) rebase)))
      (should exec-index)
      (dolist (fragment '("commit" "--amend" "--trailer" "Maduin-Model"))
        (should (string-match-p (regexp-quote fragment) command))))))

(ert-deftest maduin-test-pipeline-land-stamp-failure-retries-unstamped ()
  :tags '(maduin)
  (let* ((calls nil)
         (logged nil)
         (rebases 0)
         (stamp '(:model "gpt-5.6-terra" :backend kiro))
         (maduin-pipeline--worktree-path-fn (lambda (_seat) maduin-test--dir))
         (maduin-pipeline--branch-fn (lambda (_seat) "seat-branch-xyz"))
         (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
         (maduin-pipeline--git-fn (lambda (_dir &rest args) (push args calls) 0))
         (maduin-pipeline--git-output-fn
          (lambda (_dir &rest args)
            (push args calls)
            (cond
             ((member "commit" args) (cons 0 ""))
             ((member "rev-parse" args) (cons 0 "abc123\n"))
             ((member "rebase" args)
              (cl-incf rebases)
              (if (= rebases 1) (cons 1 "fatal: unknown option --trailer\n")
                (cons 0 "")))
             ((member "merge" args) (cons 0 ""))))))
    (cl-letf (((symbol-function 'maduin-workspace--log-warning)
               (lambda (message) (setq logged message))))
      (should (eq (maduin-pipeline-land-branch "ifrit" stamp) t)))
    (let ((rebase-calls (nreverse
                         (cl-remove-if-not (lambda (args) (equal (cadr args) "main")) calls))))
      (should (= (length rebase-calls) 2))
      (should (member "--exec" (car rebase-calls)))
      (should-not (member "--exec" (cadr rebase-calls))))
    (should (member '("rebase" "--abort") calls))
    (should (member '("merge" "--ff-only" "seat-branch-xyz") calls))
    (should (string-match-p "unstamped" logged))))

(ert-deftest maduin-test-pipeline-land-stamp-double-failure-nil ()
  :tags '(maduin)
  (let* ((calls nil)
         (stamp '(:model "gpt-5.6-terra" :backend kiro))
         (maduin-pipeline--worktree-path-fn (lambda (_seat) maduin-test--dir))
         (maduin-pipeline--branch-fn (lambda (_seat) "seat-branch-xyz"))
         (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
         (maduin-pipeline--git-fn (lambda (_dir &rest args) (push args calls) 0))
         (maduin-pipeline--git-output-fn
          (lambda (_dir &rest args)
            (push args calls)
            (cond
             ((member "commit" args) (cons 0 ""))
             ((member "rev-parse" args) (cons 0 "abc123\n"))
             ((member "rebase" args) (cons 1 "fatal: rebase failed\n"))))))
    (should-not (maduin-pipeline-land-branch "ifrit" stamp))
    (should (= 2 (length (cl-remove-if-not (lambda (args) (equal (cadr args) "main")) calls))))
    (should-not (cl-some (lambda (args) (member "merge" args)) calls))))

(ert-deftest maduin-test-pipeline-land-stamped-conflict-no-retry ()
  :tags '(maduin)
  (let* ((calls nil)
         (stamp '(:model "gpt-5.6-terra" :backend kiro))
         (maduin-pipeline--worktree-path-fn (lambda (_seat) maduin-test--dir))
         (maduin-pipeline--branch-fn (lambda (_seat) "seat-branch-xyz"))
         (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
         (maduin-pipeline--git-fn (lambda (_dir &rest args) (push args calls) 0))
         (maduin-pipeline--git-output-fn
          (lambda (_dir &rest args)
            (push args calls)
            (cond
             ((member "commit" args) (cons 0 ""))
             ((member "rev-parse" args) (cons 0 "abc123\n"))
             ((member "rebase" args) (cons 1 "CONFLICT (content): foo.el\n"))))))
    (should (eq (maduin-pipeline-land-branch "ifrit" stamp) 'conflict))
    (should (= 1 (length (cl-remove-if-not (lambda (args) (equal (cadr args) "main")) calls))))
    (should (= 1 (length (cl-remove-if-not
                          (lambda (args) (equal args '("rebase" "--abort"))) calls))))))

(defun maduin-test--stamp-git (dir &rest args)
  "Run git with ARGS in DIR and return (STATUS . OUTPUT)."
  (with-temp-buffer
    (cons (apply #'process-file "git" nil t nil "-C" dir args)
          (buffer-string))))

(defun maduin-test--stamp-git-ok (dir &rest args)
  "Run git with ARGS in DIR, asserting success, then return its output."
  (let ((result (apply #'maduin-test--stamp-git dir args)))
    (should (zerop (car result)))
    (cdr result)))

(defun maduin-test--stamp-integration-setup (root)
  "Create a main repo plus two committed changes in a registered seat worktree.
Return a plist containing the seat path and main's initial commit."
  (let ((seat (expand-file-name "seat" root))
        (hooks (expand-file-name "hooks" root)))
    (make-directory hooks)
    (maduin-test--stamp-git-ok root "init" "-b" "main")
    (maduin-test--stamp-git-ok root "config" "user.name" "Maduin Test")
    (maduin-test--stamp-git-ok root "config" "user.email" "maduin@example.test")
    (maduin-test--stamp-git-ok root "config" "commit.gpgsign" "false")
    (maduin-test--stamp-git-ok root "config" "core.hooksPath" hooks)
    (with-temp-file (expand-file-name "README" root) (insert "initial\n"))
    (maduin-test--stamp-git-ok root "add" "README")
    (maduin-test--stamp-git-ok root "commit" "-m" "initial subject")
    (let ((initial (string-trim
                    (maduin-test--stamp-git-ok root "rev-parse" "HEAD"))))
      (maduin-test--stamp-git-ok root "worktree" "add" "-b" "stamp-seat" seat)
      (with-temp-file (expand-file-name "one.txt" seat) (insert "one\n"))
      (maduin-test--stamp-git-ok seat "add" "one.txt")
      (maduin-test--stamp-git-ok seat "commit" "-m" "first stamped subject")
      (with-temp-file (expand-file-name "two.txt" seat) (insert "two\n"))
      (maduin-test--stamp-git-ok seat "add" "two.txt")
      (maduin-test--stamp-git-ok seat "commit" "-m" "second stamped subject")
      (list :seat seat :initial initial))))

(defun maduin-test--stamp-integration-land (root seat stamp)
  "Land registered SEAT into ROOT using STAMP through real git seams."
  (let ((maduin-pipeline--worktree-path-fn (lambda (_seat) seat))
        (maduin-pipeline--branch-fn (lambda (_seat) "stamp-seat"))
        (maduin-pipeline--main-root-fn (lambda () root))
        (maduin-pipeline--git-fn #'maduin-pipeline--git)
        (maduin-pipeline--git-output-fn #'maduin-pipeline--git-output))
    (maduin-pipeline-land-branch "stamp-seat" stamp)))

(defun maduin-test--stamp-integration-commits (root initial)
  "Return landed commits after INITIAL, oldest first."
  (split-string
   (string-trim
    (maduin-test--stamp-git-ok root "rev-list" "--reverse" "main"
                                (concat "^" initial)))
   "\n" t))

(ert-deftest maduin-test-stamp-integration-land-stamps-commits ()
  :tags '(maduin)
  (skip-unless (executable-find "git"))
  (let ((root (make-temp-file "maduin-stamp" t)))
    (unwind-protect
        (let* ((repo (maduin-test--stamp-integration-setup root))
               (seat (plist-get repo :seat))
               (initial (plist-get repo :initial))
               (stamp '(:model "gpt-5.6-terra" :effort "high")))
          (should (eq (maduin-test--stamp-integration-land root seat stamp) t))
          (let ((commits (maduin-test--stamp-integration-commits root initial)))
            (should (equal (mapcar (lambda (commit)
                                     (car (split-string
                                           (maduin-test--stamp-git-ok
                                            root "show" "-s" "--format=%B" commit)
                                           "\n")))
                                   commits)
                           '("first stamped subject" "second stamped subject")))
            (should (= (length commits) 2))
            (dolist (commit commits)
              (should (zerop (car (maduin-test--stamp-git
                                    root "merge-base" "--is-ancestor" commit "main"))))
              (let ((trailers (maduin-stamp-parse
                               (maduin-test--stamp-git-ok
                                root "show" "-s" "--format=%B" commit))))
                (should (equal (cdr (assoc-string "Maduin-Model" trailers))
                               "gpt-5.6-terra"))
                (should (equal (cdr (assoc-string "Maduin-Effort" trailers))
                               "high"))))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest maduin-test-stamp-integration-reland-no-duplicate-trailers ()
  :tags '(maduin)
  (skip-unless (executable-find "git"))
  (let ((root (make-temp-file "maduin-stamp" t)))
    (unwind-protect
        (let* ((repo (maduin-test--stamp-integration-setup root))
               (seat (plist-get repo :seat))
               (initial (plist-get repo :initial))
               (stamp '(:model "gpt-5.6-terra" :effort "high")))
          (should (eq (maduin-test--stamp-integration-land root seat stamp) t))
          (let ((first-land (maduin-test--stamp-integration-commits root initial)))
            (should (eq (maduin-test--stamp-integration-land root seat stamp) t))
            (let ((reland (maduin-test--stamp-integration-commits root initial)))
              (should (equal reland first-land))
              (should (= (length reland) 2))
              (dolist (commit reland)
                (let ((trailers (maduin-stamp-parse
                                 (maduin-test--stamp-git-ok
                                  root "show" "-s" "--format=%B" commit))))
                  (should (= (cl-count-if
                              (lambda (trailer)
                                (equal (car trailer) "Maduin-Model"))
                              trailers)
                             1)))))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest maduin-test-config-workspaces-keys ()
  :tags '(maduin)
  ;; `land-on-stop' was schema and config with no reader anywhere; a config
  ;; key that nothing honours is a lie, so it is gone rather than wired.
  (let ((ws (cdr (assq 'workspaces maduin-config))))
    (should (stringp (alist-get 'path ws)))
    (should-not (assq 'land-on-stop ws))
    (should-not (maduin-config--option-spec 'workspaces 'land-on-stop))))

;;; 11. repairer config

(ert-deftest maduin-test-config-repairer-keys ()
  :tags '(maduin)
  (let ((repairer (cdr (assq 'repairer maduin-config))))
    (should (eq (alist-get 'enabled repairer) t))
    (should (string= (alist-get 'model repairer) "opencode-go/deepseek-v4-pro"))
    (should (= (alist-get 'max-retries repairer) 3))))

;;; 12. project root

(ert-deftest maduin-test-project-root-returns-dir ()
  :tags '(maduin)
  (let ((root (maduin-project-root)))
    (should (stringp root))
    (should (file-directory-p root))))

(ert-deftest maduin-test-project-root-fallback ()
  :tags '(maduin)
  (let ((dir (maduin-test--temp-dir)))
    (unwind-protect
        (let ((default-directory dir))
          (should (equal (directory-file-name (maduin-project-root))
                         (directory-file-name dir))))
      (delete-directory dir t))))

(ert-deftest maduin-test-handoff-cache-under-project-root ()
  :tags '(maduin)
  (should (equal (maduin-handoff-cache-path "root-seat-xyz")
                 (expand-file-name
                  ".agents/handoff/root-seat-xyz.md"
                  (maduin-project-root)))))

;;; 13. bd scratch helpers

(defun maduin-test--bd-delete (id)
  "Force-delete scratch bead ID. Never errors."
  (condition-case nil
      (call-process shell-file-name nil nil nil shell-command-switch
                    (format "bd delete %s --force" id))
    (error nil)))

;;; 14. terminal (interactive substrate)

(ert-deftest maduin-test-terminal-buffer-name ()
  :tags '(maduin)
  (should (equal (maduin-terminal--buffer-name 'concierge "alexander")
                 "*maduin/concierge-alexander*"))
  (should (equal (maduin-terminal--buffer-name "designer" "ramuh")
                 "*maduin/designer-ramuh*")))

(ert-deftest maduin-test-terminal-choose-backend ()
  :tags '(maduin)
  (should (eq (maduin-terminal--choose-backend t) 'vterm))
  (should (eq (maduin-terminal--choose-backend nil) 'term))
  ;; batch: vterm not installed → term fallback
  (should (eq (maduin-terminal--backend) 'term)))

(ert-deftest maduin-test-terminal-prompt-inline ()
  :tags '(maduin)
  (let ((p (maduin-terminal--prompt "alexander" 'concierge "pro")))
    (should (string-match-p "alexander" p))
    (should (string-match-p "concierge" p))))

(ert-deftest maduin-test-terminal-prompt-template ()
  :tags '(maduin)
  ;; "crew" has templates/crew-prompt.txt → template wins, substituted.
  (let ((p (maduin-terminal--prompt "ant" "crew" "deepseek-v3")))
    (should (string-match-p "ant" p))
    (should-not (string-match-p "{name}" p))
    (should-not (string-match-p "{model}" p))))

(ert-deftest maduin-test-terminal-command-line ()
  :tags '(maduin)
  (let ((cmd (maduin-terminal--command-line "/acme/root" "deepseek-v3"
                                             "You are x" "opencode")))
    (should (string-match-p "\\`opencode " cmd))
    (should (string-match-p "deepseek-v3" cmd))
    (should (string-match-p "--prompt" cmd))))

(ert-deftest maduin-test-terminal-parse-session-ids ()
  :tags '(maduin)
  (let ((root "/acme/demo")
        (json (concat
               "[{\"id\":\"ses_old\",\"directory\":\"/acme/demo\",\"created\":1000},"
               "{\"id\":\"ses_new\",\"directory\":\"/acme/demo\",\"created\":2000},"
               "{\"id\":\"ses_other\",\"directory\":\"/acme/other\",\"created\":3000}]")))
    (should (equal (mapcar #'cdr (maduin-terminal--parse-session-ids json root))
                   '("ses_new" "ses_old")))
    (should (null (maduin-terminal--parse-session-ids json "/acme/missing")))
    ;; since filter (seconds): 1.5s → 1500ms, drops ses_old(1000).
    (should (equal (mapcar #'cdr (maduin-terminal--parse-session-ids json root 1.5))
                   '("ses_new")))
    ;; since 2.5s → 2500ms, drops both.
    (should (null (maduin-terminal--parse-session-ids json root 2.5)))
    ;; exclude ses_new → only ses_old.
    (should (equal (mapcar #'cdr (maduin-terminal--parse-session-ids json root nil '("ses_new")))
                   '("ses_old")))))

(ert-deftest maduin-test-terminal-handoff-note-write ()
  :tags '(maduin)
  (let* ((seat (format "ert-term-seat-%s" (format-time-string "%H%M%S%N" (current-time))))
         (note (maduin-terminal--handoff-note "ses_test123" "{\"ok\":true}"))
         (path (maduin-handoff-cache-path seat)))
    (unwind-protect
        (progn
          (should (maduin-terminal--write-handoff seat note (maduin-project-root)))
          (should (file-exists-p path))
          (should (string= (maduin-handoff-read seat) note)))
      (ignore-errors (delete-file path)))))

(ert-deftest maduin-test-terminal-active-p-bogus ()
  :tags '(maduin)
  (should-not (maduin-terminal-active-p "no-such-seat-xyz")))

(ert-deftest maduin-test-terminal-dismiss-no-buffer ()
  :tags '(maduin)
  (should (null (maduin-terminal-dismiss "no-such-seat-xyz"))))

;;; 15. dispatch

(ert-deftest maduin-test-dispatch-functions-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-dispatch-start
               maduin-dispatch-stop
               maduin-dispatch-implement
               maduin-dispatch-design
               maduin-dispatch-repair
               maduin-dispatch-run-loop))
    (should (fboundp f))))

(ert-deftest maduin-test-dispatch-implement-concurrency-cap ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (run-count 0)
         (maduin-dispatch--active
          (list (list :handle "s-ifrit" :seat "ifrit" :role 'implementer :task "t0")
                (list :handle "s-shiva" :seat "shiva" :role 'implementer :task "t0")))
         (maduin-dispatch--session-run-fn
          (lambda (_w _m _a _p _b &optional _effort)
            (setq run-count (1+ run-count))
            (format "s-%d" run-count)))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir)))
    (unwind-protect
        (progn
          ;; 2 active → 1 more on free seat titan.
          (let ((sid (maduin-dispatch-implement "t1")))
            (should (stringp sid))
            (should (= (length maduin-dispatch--active) 3))
            (should (equal (plist-get (car maduin-dispatch--active) :seat)
                           "titan")))
          ;; 3 active (cap) → nil, no further spawn.
          (let ((before run-count))
            (should-not (maduin-dispatch-implement "t2"))
            (should (= run-count before))))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-completion-lands-and-closes ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (landed nil)
         (closed nil)
         (deleted '())
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p _b &optional _effort) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--diff-fn
          (lambda (_backend _sid) (list '((file . "a.el") (patch . "+x")))))
         (maduin-dispatch--land-fn (lambda (seat &optional _stamp) (setq landed seat) t))
         (maduin-dispatch--landed-fn (lambda (_seat) t))
         (maduin-dispatch--close-fn (lambda (task out &optional _dir) (setq closed (cons task out)) t))
         (maduin-dispatch--session-delete-fn (lambda (_backend sid) (push sid deleted) t)))
    (unwind-protect
        (progn
          (should (equal (maduin-dispatch-implement "t1") "s-1"))
          (should (= (length maduin-dispatch--active) 1))
          (maduin-dispatch--on-complete "s-1" 'completed)
          (should (equal landed "ifrit"))
          (should (equal (car closed) "t1"))
          (should (member "s-1" deleted))
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-completion-failure-keeps-open ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (commented nil)
         (released nil)
         (closed nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p _b &optional _effort) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--release-fn (lambda (task) (setq released task) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--comment-fn (lambda (task text) (setq commented (cons task text)) t))
          (maduin-dispatch--close-fn (lambda (task _out &optional _dir) (setq closed task) t))
         (maduin-dispatch--session-delete-fn (lambda (_backend _sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")
          (maduin-dispatch--on-complete "s-1" 'failed)
          (should (equal (car commented) "t1"))
          ;; Failed session must release the claim (status → open).
          (should (equal released "t1"))
          (should-not closed)
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-land-not-in-main-releases ()
  :tags '(maduin)
  ;; Land reports success but the landed-fn gate says the branch never
  ;; reached main (maduin-zxe incident) → comment + release, never close.
  (let* ((dir (maduin-test--temp-dir))
         (commented nil)
         (released nil)
         (closed nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p _b &optional _effort) "s-landed"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--diff-fn
          (lambda (_backend _sid) (list '((file . "a.el") (patch . "+x")))))
         (maduin-dispatch--land-fn (lambda (_seat &optional _stamp) t))
         (maduin-dispatch--landed-fn (lambda (_seat) nil))
         (maduin-dispatch--close-fn (lambda (task _out &optional _dir) (setq closed task) t))
         (maduin-dispatch--comment-fn (lambda (task text) (setq commented (cons task text)) t))
         (maduin-dispatch--release-fn (lambda (task) (setq released task) t))
         (maduin-dispatch--session-delete-fn (lambda (_backend _sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")
          (maduin-dispatch--on-complete "s-landed" 'completed)
          (should-not closed)
          (should (equal (car commented) "t1"))
          (should (string-match-p "not in main" (cdr commented)))
          (should (equal released "t1"))
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-usage-limit-falls-back ()
  :tags '(maduin)
  ;; A usage-limited implementer session re-dispatches on the fallback
  ;; (go flash) model, holding the claim; a second failure releases it.
  (let* ((dir (maduin-test--temp-dir))
         (run-count 0)
         (last-model nil)
         (commented nil)
         (released nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn
          (lambda (_w m _a _p _b &optional _effort)
            (setq run-count (1+ run-count))
            (setq last-model m)
            (format "s-%d" run-count)))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--release-fn (lambda (task) (setq released task) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--comment-fn (lambda (task text) (setq commented (cons task text)) t))
         (maduin-dispatch--session-delete-fn (lambda (_backend _sid) t)))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-session-usage-limited-p)
                   (lambda (_sid) t)))
          (maduin-dispatch-implement "t1")
          (should (string= last-model "opencode/deepseek-v4-flash-free"))
          ;; Usage limit → fallback re-dispatch (go flash), claim held.
          (maduin-dispatch--on-complete "s-1" 'failed)
          (should (= run-count 2))
          (should (string= last-model "opencode-go/deepseek-v4-flash"))
          (should (equal commented
                         '("t1" . "usage limit — retrying with fallback model")))
          (should-not released)
          (should (= (length maduin-dispatch--active) 1))
          ;; Fallback already attempted → second failure releases.
          (maduin-dispatch--on-complete "s-2" 'failed)
          (should (= run-count 2))
          (should (equal released "t1"))
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-completion-conflict-dispatches-repairer ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (run-count 0)
         (commented nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn
          (lambda (_w _m _a _p _b &optional _effort)
            (setq run-count (1+ run-count))
            (format "s-%d" run-count)))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--diff-fn (lambda (_backend _sid) nil))
         (maduin-dispatch--land-fn (lambda (_seat &optional _stamp) 'conflict))
         (maduin-dispatch--comment-fn (lambda (task text) (setq commented (cons task text)) t))
         (maduin-dispatch--close-fn (lambda (_t _o &optional _dir) t))
         (maduin-dispatch--session-delete-fn (lambda (_backend _sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")   ; run-count 1, seat ifrit
          (maduin-dispatch--on-complete "s-1" 'completed)
          ;; conflict → repairer dispatched → second session run.
          (should (= run-count 2))
          (should (equal (car commented) "t1"))
          (should (cl-find-if (lambda (e) (eq (plist-get e :role) 'repairer))
                              maduin-dispatch--active)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-completion-land-fail-releases ()
  :tags '(maduin)
  ;; Non-conflict land failure (nil) must release the claim so the task
  ;; returns to open instead of staying in_progress forever.
  (let* ((dir (maduin-test--temp-dir))
         (released nil)
         (closed nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p _b &optional _effort) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--release-fn (lambda (task) (setq released task) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--diff-fn (lambda (_backend _sid) nil))
         (maduin-dispatch--land-fn (lambda (_seat &optional _stamp) nil))
         (maduin-dispatch--comment-fn (lambda (_task _text) t))
         (maduin-dispatch--close-fn (lambda (task _o &optional _dir) (setq closed task) t))
         (maduin-dispatch--session-delete-fn (lambda (_backend _sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")
          (maduin-dispatch--on-complete "s-1" 'completed)
          (should (equal released "t1"))
          (should-not closed))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-run-loop-dispatches-ready ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (run-count 0)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn
          (lambda (_w _m _a _p _b &optional _effort)
            (setq run-count (1+ run-count))
            (format "s-%d" run-count)))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--ready-fn (lambda () '("t1" "t2")))
         (maduin-dispatch--in-progress-fn (lambda () nil))
         (maduin-dispatch--open-epics-fn (lambda () nil))
         (maduin-dispatch--drift-fix-async-fn
          (lambda (callback) (funcall callback nil t) (quote drift-fix)))
         (maduin-dispatch--in-progress-async-fn
          (lambda (callback) (funcall callback nil t) 'in-progress))
         (maduin-dispatch--ready-async-fn
          (lambda (callback) (funcall callback '("t1" "t2") t) 'ready))
         (maduin-dispatch--open-epics-async-fn
          (lambda (callback) (funcall callback nil t) 'epics)))
    (unwind-protect
        (progn
          (maduin-dispatch-run-loop)
          (should (= run-count 2))
          (should (= (length maduin-dispatch--active) 2)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-orphaned-tasks ()
  :tags '(maduin)
  ;; in_progress tasks with a live dispatch session are NOT orphans.
  (let ((maduin-dispatch--in-progress-fn (lambda () '("o1" "o2" "live")))
        (maduin-dispatch--active
         (list (list :handle "s-1" :seat "ifrit" :role 'implementer :task "live"))))
    (should (equal (maduin-dispatch--orphaned-tasks) '("o1" "o2")))))

(ert-deftest maduin-test-dispatch-recover-redispatches-orphans ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (run-count 0)
         (maduin-dispatch--active nil)
         (maduin-dispatch--in-progress-fn (lambda () '("orphan-1")))
         (maduin-dispatch--session-run-fn
          (lambda (_w _m _a _p _b &optional _effort)
            (setq run-count (1+ run-count))
            (format "s-%d" run-count)))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir)))
    (unwind-protect
        (progn
          (should (= (maduin-dispatch--recover) 1))
          (should (= run-count 1))
          (should (cl-find-if (lambda (e) (string= (plist-get e :task) "orphan-1"))
                              maduin-dispatch--active)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-start-stop-timer ()
  :tags '(maduin)
  (let ((maduin-dispatch--timer nil)
        (maduin-dispatch--active nil)
        (maduin-dispatch--in-progress-fn (lambda () nil))
        (maduin-dispatch--session-delete-fn (lambda (_backend _sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-start)
          (should maduin-dispatch--timer)
          (maduin-dispatch-stop)
          (should-not maduin-dispatch--timer))
      (maduin-dispatch-stop))))

(ert-deftest maduin-test-dispatch-soft-stop-drains ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (deleted '())
         (maduin-dispatch--active nil)
         (maduin-dispatch--draining nil)
         (maduin-dispatch--timer nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p _b &optional _effort) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--diff-fn (lambda (_backend _sid) nil))
         (maduin-dispatch--land-fn (lambda (_seat &optional _stamp) t))
         (maduin-dispatch--close-fn (lambda (_t _o &optional _dir) t))
         (maduin-dispatch--session-delete-fn (lambda (_backend sid) (push sid deleted) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")
          (should (= (length maduin-dispatch--active) 1))
          ;; Soft stop: draining set, in-flight session NOT deleted.
          (maduin-dispatch-stop)
          (should maduin-dispatch--draining)
          (should (= (length maduin-dispatch--active) 1))
          (should-not deleted)
          ;; Run-loop is a no-op while draining (no new picks).
          (let ((maduin-dispatch--ready-fn (lambda () '("t2"))))
            (maduin-dispatch-run-loop)
            (should (= (length maduin-dispatch--active) 1)))
          ;; Last session completes → drained + deleted.
          (maduin-dispatch--on-complete "s-1" 'completed)
          (should-not maduin-dispatch--draining)
          (should-not maduin-dispatch--active)
          (should (member "s-1" deleted)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-hard-stop-deletes ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (deleted '())
         (maduin-dispatch--active nil)
         (maduin-dispatch--draining nil)
         (maduin-dispatch--timer nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p _b &optional _effort) "s-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--session-delete-fn (lambda (_backend sid) (push sid deleted) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")
          (should (= (length maduin-dispatch--active) 1))
          (maduin-dispatch-stop t)          ; hard
          (should-not maduin-dispatch--active)
          (should (member "s-1" deleted))
          (should-not maduin-dispatch--draining))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-undecomposed-epics ()
  :tags '(maduin)
  (let ((maduin-dispatch--open-epics-fn
         (lambda () '("epic-a" "epic-b" "epic-c")))
        (maduin-dispatch--epic-children-fn
         (lambda (epic)
           (cond ((string= epic "epic-a") '("t1" "t2"))
                 ((string= epic "epic-b") '("t3"))
                 (t nil)))))
    (should (equal (maduin-dispatch--undecomposed-epics)
                   '("epic-c")))))

(ert-deftest maduin-test-dispatch-undecomposed-epics-none-open ()
  :tags '(maduin)
  (let ((maduin-dispatch--open-epics-fn (lambda () nil)))
    (should-not (maduin-dispatch--undecomposed-epics))))

(ert-deftest maduin-test-dispatch-run-loop-decomposes-epics ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (decomposed '())
         (run-count 0)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn
          (lambda (_w _m _a _p _b &optional _effort)
            (setq run-count (1+ run-count))
            (format "s-%d" run-count)))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--ready-fn (lambda () '("t1")))
         (maduin-dispatch--in-progress-fn (lambda () nil))
         (maduin-dispatch--open-epics-fn
          (lambda () '("epic-x" "epic-y")))
         (maduin-dispatch--epic-children-fn
          (lambda (epic)
            (when (string= epic "epic-x") '("c1"))))
         (maduin-dispatch--epic-decompose-fn
          (lambda (epic) (push epic decomposed)
            (maduin-dispatch-design epic)))
         (maduin-dispatch--drift-fix-async-fn
          (lambda (callback) (funcall callback nil t) (quote drift-fix)))
         (maduin-dispatch--in-progress-async-fn
          (lambda (callback) (funcall callback nil t) 'in-progress))
         (maduin-dispatch--ready-async-fn
          (lambda (callback) (funcall callback '("t1") t) 'ready))
         (maduin-dispatch--open-epics-async-fn
          (lambda (callback) (funcall callback '("epic-x" "epic-y") t) 'epics))
         (maduin-dispatch--epic-children-async-fn
          (lambda (epic callback)
            (funcall callback (when (string= epic "epic-x") '("c1")) t)
            epic)))
    (unwind-protect
        (progn
          ;; epic-x has children → skipped; epic-y lacks decomposition.
          (maduin-dispatch-run-loop)
          (should (equal decomposed '("epic-y")))
          ;; 1 implementer + 1 designer session.
          (should (= run-count 2))
          (should (= (length maduin-dispatch--active) 2)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-designer-completion-does-not-close ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (landed nil)
         (closed nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p _b &optional _effort) "s-des-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir))
         (maduin-dispatch--diff-fn (lambda (_backend _sid) nil))
         (maduin-dispatch--land-fn (lambda (seat &optional _stamp) (setq landed seat) t))
         (maduin-dispatch--close-fn (lambda (task _out &optional _dir) (setq closed task) t))
         (maduin-dispatch--session-delete-fn (lambda (_backend _sid) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-design "epic-z")
          (should (= (length maduin-dispatch--active) 1))
          (maduin-dispatch--on-complete "s-des-1" 'completed)
          ;; designer session: lands but does NOT close the epic.
          (should (equal landed "ramuh"))
          (should-not closed)
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

;;; 16. designer (Ramuh)

(ert-deftest maduin-test-designer-functions-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-designer-design
               maduin-designer-decompose-epic
               maduin-designer-drop-in
               maduin-designer-pending-tasks))
    (should (fboundp f))))

(ert-deftest maduin-test-designer-epic-prompt-template ()
  :tags '(maduin)
  (let ((tmpl (maduin-designer--epic-template)))
    (should (stringp tmpl))
    (should (string-match-p "{id}" tmpl))
    (should (string-match-p "decompos" (downcase tmpl)))
    (should (string-match-p "--parent" tmpl))
    (should (string-match-p "staged" (downcase tmpl)))
    (should (string-match-p "--design" tmpl))
    (should (string-match-p "--acceptance" tmpl))
    (should (string-match-p "--deps" tmpl))
    (should (string-match-p "implementation instructions" (downcase tmpl)))
    (should (string-match-p "files" (downcase tmpl)))
    (should (string-match-p "interfaces" (downcase tmpl)))
    (should (string-match-p "bd show" tmpl))
    (should (string-match-p "do not implement" (downcase tmpl)))
    (should (string-match-p "do not close" (downcase tmpl)))))

(ert-deftest maduin-test-designer-decompose-epic-dispatches ()
  :tags '(maduin)
  (let* ((captured-task nil)
         (captured-plan nil)
         (maduin-designer--show-fn
          (lambda (_t) (list :title "E-Body" :desc "E-Desc")))
         (maduin-designer--dispatch-fn
          (lambda (task plan)
            (setq captured-task task)
            (setq captured-plan plan)
            "s-epic-1")))
    (should (equal (maduin-designer-decompose-epic "maduin-ep1") "s-epic-1"))
    (should (equal captured-task "maduin-ep1"))
    (should (string-match-p "maduin-ep1" captured-plan))
    (should (string-match-p "E-Body" captured-plan))
    (should (string-match-p "E-Desc" captured-plan))
    (should (string-match-p "decompos" (downcase captured-plan)))
    (should (string-match-p "--parent" captured-plan))
    ;; placeholders fully substituted.
    (should-not (string-match-p "{id}" captured-plan))
    (should-not (string-match-p "{title}" captured-plan))
    (should-not (string-match-p "{desc}" captured-plan))))

(ert-deftest maduin-test-designer-prompt-template ()
  :tags '(maduin)
  (let ((tmpl (maduin-designer--template)))
    (should (stringp tmpl))
    (should (string-match-p "{id}" tmpl))
    (should (string-match-p "do not implement" (downcase tmpl)))
    (should (string-match-p "defer" (downcase tmpl)))
    (should (string-match-p "staged" (downcase tmpl)))
    (should (string-match-p "--design" tmpl))
    (should (string-match-p "--acceptance" tmpl))))

(ert-deftest maduin-test-designer-design-builds-prompt-and-dispatches ()
  :tags '(maduin)
  (let* ((captured-task nil)
         (captured-plan nil)
         (maduin-designer--show-fn
          (lambda (_t) (list :title "T-Body" :desc "D-Body")))
         (maduin-designer--dispatch-fn
          (lambda (task plan)
            (setq captured-task task)
            (setq captured-plan plan)
            "s-des-1")))
    (should (equal (maduin-designer-design "maduin-abc") "s-des-1"))
    (should (equal captured-task "maduin-abc"))
    (should (string-match-p "maduin-abc" captured-plan))
    (should (string-match-p "T-Body" captured-plan))
    (should (string-match-p "D-Body" captured-plan))
    (should (string-match-p "do not implement" (downcase captured-plan)))
    (should (string-match-p "staged" (downcase captured-plan)))
    (should (string-match-p "defer" (downcase captured-plan)))
    ;; {id}/{title}/{desc} placeholders fully substituted.
    (should-not (string-match-p "{id}" captured-plan))
    (should-not (string-match-p "{title}" captured-plan))
    (should-not (string-match-p "{desc}" captured-plan))))

(ert-deftest maduin-test-designer-design-plan-override ()
  :tags '(maduin)
  (let* ((got-plan nil)
         (maduin-designer--dispatch-fn
          (lambda (_task plan) (setq got-plan plan) "s-des-2")))
    (should (equal (maduin-designer-design "maduin-abc" "CUSTOM PLAN")
                   "s-des-2"))
    (should (equal got-plan "CUSTOM PLAN"))))

(ert-deftest maduin-test-designer-pending-tasks ()
  :tags '(maduin)
  (let* ((maduin-designer--query-fn
          (lambda (_q) '("t-with-design" "t-no-design" "t-no-design2")))
         (maduin-designer--has-design-fn
          (lambda (id) (string= id "t-with-design"))))
    (should (equal (maduin-designer-pending-tasks)
                   '("t-no-design" "t-no-design2")))))

(ert-deftest maduin-test-designer-pending-tasks-empty ()
  :tags '(maduin)
  (let ((maduin-designer--query-fn (lambda (_q) nil)))
    (should (null (maduin-designer-pending-tasks)))))

(ert-deftest maduin-test-designer-drop-in-delegates ()
  :tags '(maduin)
  (let* ((got-seat nil)
         (got-role nil)
         (got-model nil)
         (maduin-designer--terminal-open-fn
          (lambda (seat role model)
            (setq got-seat seat)
            (setq got-role role)
            (setq got-model model)
            (get-buffer-create " *ert-designer-dropin*"))))
    (unwind-protect
        (progn
          (should (bufferp (maduin-designer-drop-in "ramuh")))
          (should (equal got-seat "ramuh"))
          (should (eq got-role 'designer))
          (should (string= got-model "opencode-go/deepseek-v4-pro")))
      (when (get-buffer " *ert-designer-dropin*")
        (kill-buffer " *ert-designer-dropin*")))))

;;; 17. concierge (Alexander)

(ert-deftest maduin-test-concierge-functions-exist ()
  :tags '(maduin)
  (dolist (f '(maduin-concierge maduin-concierge-dismiss))
    (should (fboundp f))))

(ert-deftest maduin-test-concierge-model-resolution ()
  :tags '(maduin)
  (should (equal (maduin-concierge--seat-model "alexander")
                 "opencode-go/deepseek-v4-pro"))
  (should (equal (maduin-concierge--model) "opencode-go/deepseek-v4-pro")))

(ert-deftest maduin-test-concierge-summon ()
  :tags '(maduin)
  (let* ((called nil)
         (maduin-concierge--terminal-open-fn
          (lambda (seat role model) (setq called (list seat role model)))))
    (maduin-concierge)
    (should (equal called
                   '("alexander" concierge "opencode-go/deepseek-v4-pro")))))

(ert-deftest maduin-test-concierge-dismiss ()
  :tags '(maduin)
  (let* ((dismissed nil)
         (maduin-concierge--terminal-dismiss-fn
          (lambda (seat) (setq dismissed seat) "handoff-note-123")))
    (should (equal (maduin-concierge-dismiss) "handoff-note-123"))
    (should (equal dismissed "alexander"))))

(ert-deftest maduin-test-concierge-prompt-template ()
  :tags '(maduin)
  (let ((tmpl (maduin-terminal--template "concierge")))
    (should (stringp tmpl))
    (should (string-match-p "epic" tmpl))
    (should (string-match-p "--design" tmpl))
    (should (string-match-p "design doc" tmpl))
    (should (string-match-p "Do not decompose" tmpl))
    (should (string-match-p "Do not implement" tmpl))))

;;; 18. integration (entry point wiring)

(ert-deftest maduin-test-main-interactive-commands ()
  :tags '(maduin)
  (dolist (f '(maduin-concierge
               maduin-concierge-dismiss
               maduin-designer-drop-in
               maduin-designer-pending-tasks
               maduin-start
               maduin-stop))
    (should (commandp f))))

(ert-deftest maduin-test-main-keymap-bindings ()
  :tags '(maduin)
  (dolist (pair '(("C-c s c" . maduin-concierge)
                  ("C-c s d" . maduin-concierge-dismiss)
                  ("C-c s n" . maduin-designer-drop-in)
                  ("C-c s p" . maduin-designer-pending-tasks)))
    (should (eq (lookup-key maduin-mode-map (kbd (car pair))) (cdr pair)))))

(ert-deftest maduin-test-main-start-zero-sessions ()
  :tags '(maduin)
  (let ((maduin-dispatch--timer nil)
        (maduin-dispatch--active nil)
        (maduin-dispatch--in-progress-fn (lambda () nil))
        (maduin-dispatch--session-run-fn
         (lambda (_w _m _a _p _b &optional _effort) (ert-fail "maduin-start must not spawn sessions")))
        (maduin-dispatch--session-delete-fn (lambda (_backend _sid) t)))
    (unwind-protect
        (progn
          (maduin-start)
          (should maduin-dispatch--timer)     ; dispatchers active
          (should-not maduin-dispatch--active)) ; zero sessions spawned
      (maduin-dispatch-stop))))

(ert-deftest maduin-test-main-stop-tears-down ()
  :tags '(maduin)
  (let* ((maduin-dispatch--timer nil)
         (maduin-dispatch--active
          (list (list :handle "s-stop-1" :seat "ifrit" :role 'implementer :task "t1")))
         (deleted '())
         (maduin-dispatch--session-delete-fn (lambda (_backend sid) (push sid deleted) t)))
    (unwind-protect
        (progn
          (maduin-stop t)                  ; hard stop tears down live sessions
          (should-not maduin-dispatch--timer)
          (should-not maduin-dispatch--active)
          (should (member "s-stop-1" deleted)))
      (maduin-dispatch-stop t))))

;;; 19. full-loop integration (mock opencode, chained seams)

(ert-deftest maduin-test-full-loop-epic-to-close ()
  :tags '(maduin)
  (let* ((epic "ert-epic-fake")
         (task "ert-epic-fake.1"))
    (cl-letf (((symbol-function 'maduin-bd-create-epic)
               (lambda (_title _desc) "ert-epic-fake"))
              ((symbol-function 'maduin-bd-create-task)
               (lambda (_title _desc _parent) "ert-epic-fake.1"))
              ((symbol-function 'maduin-bd-defer)
               (lambda (_id) t))
              ((symbol-function 'maduin-bd-update-design-acceptance)
               (lambda (_id _design _acceptance) t))
              ((symbol-function 'maduin-bd-undefer)
               (lambda (_id) t))
              ((symbol-function 'maduin-bd-ready-tasks)
               (lambda () (list "ert-epic-fake.1"))))
      (ignore epic)
      ;; 1. a deferred task is filed for the designer (Ramuh).
      (should (maduin-bd-defer task))
      ;; 2. designer fills design + stages (defer + staged label).
      (should (maduin-bd-update-design-acceptance task "design body" "acceptance body"))
      ;; 3. approved work consumes via bd ready: undefer → ready.
      (should (maduin-bd-undefer task))
      ;; 4. appears in ready.
      (should (member task (maduin-bd-ready-tasks)))
      ;; 5. run-loop → implement session → mock complete → land → close
      ;;    (session/land/close seams mocked; no real opencode).
      (let* ((dir (maduin-test--temp-dir))
             (landed nil)
             (closed nil)
             (deleted '())
             (maduin-dispatch--active nil)
             (maduin-dispatch--ready-fn (lambda () (list task)))
             (maduin-dispatch--in-progress-fn (lambda () nil))
             (maduin-dispatch--open-epics-fn (lambda () nil))
             (maduin-dispatch--drift-fix-async-fn
              (lambda (callback) (funcall callback nil t) (quote drift-fix)))
             (maduin-dispatch--in-progress-async-fn
              (lambda (callback) (funcall callback nil t) 'in-progress))
             (maduin-dispatch--ready-async-fn
              (lambda (callback) (funcall callback (list task) t) 'ready))
             (maduin-dispatch--open-epics-async-fn
              (lambda (callback) (funcall callback nil t) 'epics))
             (maduin-dispatch--session-run-fn (lambda (_w _m _a _p _b &optional _effort) "s-loop-1"))
             (maduin-dispatch--claim-fn (lambda (_t) t))
             (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
             (maduin-dispatch--workdir-fn (lambda (_s) dir))
             (maduin-dispatch--diff-fn
              (lambda (_backend _sid) (list '((file . "x.el") (patch . "+1")))))
             (maduin-dispatch--land-fn (lambda (seat &optional _stamp) (setq landed seat) t))
             (maduin-dispatch--landed-fn (lambda (_seat) t))
             (maduin-dispatch--close-fn (lambda (t2 _out &optional _dir) (setq closed t2) t))
             (maduin-dispatch--session-delete-fn (lambda (_backend sid) (push sid deleted) t)))
        (unwind-protect
            (progn
              (maduin-dispatch-run-loop)
              (should (= (length maduin-dispatch--active) 1))
              (should (equal (plist-get (car maduin-dispatch--active) :task) task))
              (maduin-dispatch--on-complete "s-loop-1" 'completed)
              (should (equal landed "ifrit"))
              (should (equal closed task))
              (should (member "s-loop-1" deleted))
              (should-not maduin-dispatch--active))
          (delete-directory dir t))))))

;;; 20. v0.3 — batched review gate (Odin)

(ert-deftest maduin-test-review-verdict-approved ()
  :tags '(maduin)
  (should (eq (maduin-review--verdict "REVIEW: APPROVED\n") 'approved))
  (should (eq (maduin-review--verdict "blah\nREVIEW: APPROVED\nmore") 'approved)))

(ert-deftest maduin-test-review-verdict-drift ()
  :tags '(maduin)
  (should (equal (maduin-review--verdict "REVIEW: DRIFT fix the widget\n")
                 '(drift . "fix the widget")))
  (should (equal (maduin-review--verdict "noise\nREVIEW: DRIFT needs work")
                 '(drift . "needs work"))))

(ert-deftest maduin-test-review-verdict-garbage ()
  :tags '(maduin)
  (should (eq (maduin-review--verdict "no marker here") 'error))
  (should (eq (maduin-review--verdict nil) 'error)))

(ert-deftest maduin-test-review-epic-children-closed-p ()
  :tags '(maduin)
  (let ((maduin-review--epic-children-fn (lambda (_epic) '("t1" "t2")))
        (maduin-review--show-fn (lambda (_id) (list :status "closed"))))
    (should (maduin-review--epic-children-closed-p "epic-x")))
  (let ((maduin-review--epic-children-fn (lambda (_epic) '("t1" "t2")))
        (maduin-review--show-fn
         (lambda (id)
           (list :status (if (string= id "t2") "in_progress" "closed")))))
    (should-not (maduin-review--epic-children-closed-p "epic-x")))
  ;; no children → not complete.
  (let ((maduin-review--epic-children-fn (lambda (_epic) nil))
        (maduin-review--show-fn (lambda (_id) (list :status "closed"))))
    (should-not (maduin-review--epic-children-closed-p "epic-x"))))

(ert-deftest maduin-test-review-note-epic-land-records-once ()
  :tags '(maduin)
  (let ((maduin-review--epic-starts nil)
        (maduin-review--main-root-fn (lambda () "/repo"))
        (maduin-review--git-output-fn
         (lambda (_dir &rest _args) (cons 0 "sha-pre-first\n"))))
    (should (maduin-review--note-epic-land "epic-x"))
    (should (equal (cdr (assoc "epic-x" maduin-review--epic-starts))
                   "sha-pre-first"))
    ;; later lands keep the original start.
    (should-not (maduin-review--note-epic-land "epic-x"))))

(ert-deftest maduin-test-review-epic-diff ()
  :tags '(maduin)
  (let ((maduin-review--epic-starts '(("epic-x" . "abc")))
        (maduin-review--main-root-fn (lambda () "/repo"))
        (maduin-review--git-output-fn
         (lambda (_dir &rest args)
           (cons 0 (mapconcat #'identity args " ")))))
    (should (string-match-p "abc\\.\\.HEAD" (maduin-review--epic-diff "epic-x"))))
  ;; missing start → fall back to last-land parent HEAD~1.
  (let ((maduin-review--epic-starts nil)
        (maduin-review--main-root-fn (lambda () "/repo"))
        (maduin-review--git-output-fn
         (lambda (_dir &rest args)
           (cons 0 (mapconcat #'identity args " ")))))
    (should (string-match-p "HEAD~1\\.\\.HEAD" (maduin-review--epic-diff "epic-x")))))

(ert-deftest maduin-test-review-blocked-p ()
  :tags '(maduin)
  (let ((maduin-review--query-fn (lambda (_q) '("drift-task-1"))))
    (should (maduin-review--blocked-p)))
  (let ((maduin-review--query-fn (lambda (_q) nil)))
    (should-not (maduin-review--blocked-p))))

(ert-deftest maduin-test-review-gate-approved-closes-epic ()
  :tags '(maduin)
  (let* ((maduin-review--epic-starts '(("epic-x" . "abc")))
         (cmds nil)
         (maduin-review--main-root-fn (lambda () "/repo"))
         (maduin-review--git-output-fn
          (lambda (_dir &rest args)
            (if (member "diff" args)
                (cons 0 "+fake diff\n")
              (cons 0 "abc\n"))))
         (maduin-review--query-fn (lambda (_q) nil))
         (maduin-review--session-run-fn (lambda (_w _m _a _p) "sid-1"))
         (maduin-review--complete-p-fn (lambda (_sid) 'completed))
         (maduin-review--session-output-fn (lambda (_sid) "REVIEW: APPROVED\n"))
         (maduin-review--run-fn (lambda (cmd) (push cmd cmds) (cons 0 "")))
         (maduin-review--comment-fn (lambda (_id _text) t)))
    (should (eq (maduin-review-gate "epic-x") 'approved))
    ;; goal met → epic closed.
    (should (cl-find-if (lambda (c) (string-match-p "bd close epic-x" c)) cmds))
    ;; approved → recorded start dropped.
    (should-not (assoc "epic-x" maduin-review--epic-starts))))

(ert-deftest maduin-test-review-gate-drift-creates-drift-fix ()
  :tags '(maduin)
  (let* ((maduin-review--epic-starts '(("epic-x" . "abc")))
         (cmds nil)
         (maduin-review--main-root-fn (lambda () "/repo"))
         (maduin-review--git-output-fn
          (lambda (_dir &rest _args) (cons 0 "diff")))
         (maduin-review--query-fn (lambda (_q) nil))
         (maduin-review--session-run-fn (lambda (_w _m _a _p) "sid-1"))
         (maduin-review--complete-p-fn (lambda (_sid) 'completed))
         (maduin-review--session-output-fn
          (lambda (_sid) "REVIEW: DRIFT fix the widget\n"))
         (maduin-review--run-fn (lambda (cmd) (push cmd cmds) (cons 0 "drift-task-1\n")))
         (maduin-review--comment-fn (lambda (_id _text) t)))
    (should (eq (maduin-review-gate "epic-x") 'drift))
    (should (cl-find-if (lambda (c) (string-match-p "drift-fix" c)) cmds))
    (should (cl-find-if (lambda (c) (string-match-p "widget" c)) cmds))
    ;; drift → epic stays open: no close, recorded start preserved.
    (should-not (cl-find-if (lambda (c) (string-match-p "bd close epic-x" c)) cmds))
    (should (equal (cdr (assoc "epic-x" maduin-review--epic-starts)) "abc"))))

(ert-deftest maduin-test-review-gate-disabled ()
  :tags '(maduin)
  (let ((maduin-config '((reviewer (enabled . nil)))))
    (should (null (maduin-review-gate "epic-x")))))

(ert-deftest maduin-test-review-maybe-review-epic-when-complete ()
  :tags '(maduin)
  (let* ((gate-called nil)
         (maduin-review--epic-starts nil)
         (maduin-review--show-fn
          (lambda (_id) (list :parent "epic-x" :status "closed")))
         (maduin-review--epic-children-fn (lambda (_epic) '("t1")))
         (maduin-review--main-root-fn (lambda () "/repo"))
         (maduin-review--git-output-fn
          (lambda (_dir &rest _args) (cons 0 "sha\n"))))
    (cl-letf (((symbol-function 'maduin-review-gate)
               (lambda (epic) (setq gate-called epic) 'approved)))
      (should (eq (maduin-review--maybe-review-epic "t1") 'approved))
      (should (string= gate-called "epic-x"))
      ;; start recorded before the gate ran.
      (should (equal (cdr (assoc "epic-x" maduin-review--epic-starts)) "sha")))))

(ert-deftest maduin-test-review-maybe-review-epic-not-complete ()
  :tags '(maduin)
  (let* ((gate-called nil)
         (maduin-review--show-fn
          (lambda (id)
            (if (string= id "t1")
                (list :parent "epic-x" :status "in_progress")
              (list :status "in_progress"))))
          (maduin-review--epic-children-fn (lambda (_epic) '("t1" "t2"))))
    (cl-letf (((symbol-function 'maduin-review-gate)
               (lambda (_epic) (setq gate-called t) 'approved)))
      (should (null (maduin-review--maybe-review-epic "t1")))
      (should-not gate-called))))

(ert-deftest maduin-test-review-maybe-review-epic-no-parent ()
  :tags '(maduin)
  (let* ((gate-called nil)
         (maduin-review--show-fn (lambda (_id) (list :status "closed" :parent nil))))
    (cl-letf (((symbol-function 'maduin-review-gate)
               (lambda (_epic) (setq gate-called t) 'approved)))
      (should (null (maduin-review--maybe-review-epic "orphan")))
      (should-not gate-called))))

;;; Review gate wiring: wave trigger, fleet hold, rework priority

(defmacro maduin-test--with-review-state (&rest body)
  "Run BODY with review gate runtime state isolated from other tests."
  `(let ((maduin-review--in-flight nil)
         (maduin-review--attempts nil)
         (maduin-review--exhausted nil)
         (maduin-review--epic-starts nil))
     ,@body))

(ert-deftest maduin-test-review-due-epic-records-and-limits ()
  "A completed wave is due once per attempt and stops at max-retries."
  :tags '(maduin)
  (maduin-test--with-review-state
   (let* ((comments nil)
          (maduin-review--show-fn
           (lambda (_id) (list :parent "epic-x" :status "closed")))
          (maduin-review--epic-children-fn (lambda (_epic) '("t1")))
          (maduin-review--main-root-fn (lambda () "/repo"))
          (maduin-review--git-output-fn (lambda (_dir &rest _args) (cons 0 "sha\n")))
          (maduin-review--comment-fn
           (lambda (id text) (push (cons id text) comments) t)))
     (should (equal (maduin-review-due-epic "t1") "epic-x"))
     (should (equal (cdr (assoc "epic-x" maduin-review--epic-starts)) "sha"))
     ;; A review already in flight for the epic is not re-triggered.
     (maduin-review-note-session "sid-1" "epic-x")
     (should-not (maduin-review-due-epic "t1"))
     (maduin-review--drop-session "sid-1")
     (should (equal (maduin-review-due-epic "t1") "epic-x"))
     ;; Exhausted retries report once and stop reviewing.
     (setq maduin-review--attempts '(("epic-x" . 3)))
     (should-not (maduin-review-due-epic "t1"))
     (should (= (length comments) 1))
     (should (string-match-p "exhausted" (cdr (car comments))))
     (should-not (maduin-review-due-epic "t1"))
     (should (= (length comments) 1)))))

(ert-deftest maduin-test-review-hold-covers-flight-and-rework ()
  "The fleet holds while a review runs and while drift-fix work is open."
  :tags '(maduin)
  (maduin-test--with-review-state
   (should-not (maduin-review-hold-with-p nil))
   (should (maduin-review-hold-with-p '("drift-1")))
   (maduin-review-note-session "sid-1" "epic-x")
   (should (maduin-review-hold-with-p nil))
   (should (maduin-review-in-flight-p))
   (maduin-review--drop-session "sid-1")
   (should-not (maduin-review-hold-with-p nil))
   ;; A disabled gate never holds the fleet.
   (let ((maduin-config '((reviewer (enabled . nil)))))
     (should-not (maduin-review-hold-with-p '("drift-1"))))))

(ert-deftest maduin-test-review-complete-clears-hold ()
  "Verdict handling drops the in-flight session, so a hold cannot outlive it."
  :tags '(maduin)
  (maduin-test--with-review-state
   (let* ((cmds nil)
          (maduin-review--run-fn (lambda (cmd) (push cmd cmds) (cons 0 "")))
          (maduin-review--comment-fn (lambda (_id _text) t)))
     (maduin-review-note-session "sid-1" "epic-x")
     (should (eq (maduin-review-complete "sid-1" "REVIEW: APPROVED\n") 'approved))
     (should-not (maduin-review-in-flight-p))
     (should (cl-find-if (lambda (c) (string-match-p "bd close epic-x" c)) cmds))
     ;; Approval clears the attempt budget for the epic.
     (should-not (assoc "epic-x" maduin-review--attempts))
     ;; An untracked session id is a no-op, never a stray verdict.
     (should-not (maduin-review-complete "sid-unknown" "REVIEW: APPROVED\n")))))

(ert-deftest maduin-test-review-abort-releases-hold ()
  "A failed reviewer session comments on its epic and clears the hold."
  :tags '(maduin)
  (maduin-test--with-review-state
   (let* ((comments nil)
          (maduin-review--comment-fn
           (lambda (id text) (push (cons id text) comments) t)))
     (maduin-review-note-session "sid-1" "epic-x")
     (should (equal (maduin-review-abort "sid-1" "reviewer session failed")
                    "epic-x"))
     (should-not (maduin-review-in-flight-p))
     (should (string-match-p "reviewer session failed" (cdr (car comments)))))))

(ert-deftest maduin-test-dispatch-review-spawns-unclaimed-session ()
  "Review runs in the main root on the reviewer seat and claims nothing."
  :tags '(maduin)
  (maduin-test--with-review-state
   (let* ((claimed nil)
          (received nil)
          (maduin-dispatch--active nil)
          (maduin-dispatch--claim-fn (lambda (task) (push task claimed) t))
          (maduin-pipeline--main-root-fn (lambda () "/main-root"))
          (maduin-dispatch--session-run-fn
           (lambda (workdir model agent plan backend &optional effort)
             (setq received (list workdir model agent plan backend effort))
             "review-sid")))
     (cl-letf (((symbol-function 'maduin-review-plan-for)
                (lambda (epic) (format "review %s" epic))))
       (should (equal (maduin-dispatch-review "epic-x") "review-sid"))
       (should-not claimed)
       (should (equal (nth 0 received) "/main-root"))
       (should (equal (nth 2 received) "slugineer-reviewer"))
       (should (equal (nth 3 received) "review epic-x"))
       (let ((entry (car maduin-dispatch--active)))
         (should (eq (plist-get entry :role) 'reviewer))
         (should (equal (plist-get entry :seat) "odin"))
         (should (equal (plist-get entry :task) "epic-x")))
       (should (equal (cdr (assoc "review-sid" maduin-review--in-flight))
                      "epic-x"))
       ;; Cap is one reviewer: a second request no-ops.
       (should-not (maduin-dispatch-review "epic-x"))))))

(ert-deftest maduin-test-dispatch-complete-triggers-review-after-close ()
  "Closing the wave's last task starts the gate; the gate runs after close."
  :tags '(maduin)
  (maduin-test--with-review-state
   (let* ((order nil)
          (maduin-dispatch--active nil)
          (maduin-dispatch--diff-fn (lambda (_backend _sid) nil))
          (maduin-dispatch--land-fn (lambda (_seat &optional _stamp) t))
          (maduin-dispatch--landed-fn (lambda (_seat) t))
          (maduin-dispatch--close-fn
           (lambda (task _output) (push (list 'close task) order) t))
          (maduin-dispatch--comment-fn (lambda (_id _text) t))
          (entry (list :handle "sid-1" :seat "ifrit" :role 'implementer
                       :task "t1" :backend 'opencode)))
     (cl-letf (((symbol-function 'maduin-review-due-epic)
                (lambda (task) (and (equal task "t1") "epic-x")))
               ((symbol-function 'maduin-dispatch-review)
                (lambda (epic) (push (list 'review epic) order) "review-sid")))
       (maduin-dispatch--complete entry "sid-1")
       (should (equal (nreverse order) '((close "t1") (review "epic-x"))))))))

(ert-deftest maduin-test-dispatch-complete-reviewer-parses-verdict ()
  "A reviewer session never lands or closes; its transcript becomes a verdict."
  :tags '(maduin)
  (maduin-test--with-review-state
   (let* ((landed nil)
          (closed nil)
          (maduin-dispatch--land-fn (lambda (_seat &optional _stamp) (setq landed t) t))
          (maduin-dispatch--close-fn (lambda (_task _output) (setq closed t) t))
          (maduin-dispatch--output-fn
           (lambda (_backend _sid) "REVIEW: DRIFT widget is wrong\n"))
          (verdict nil)
          (entry (list :handle "review-sid" :seat "odin" :role 'reviewer
                       :task "epic-x" :backend 'opencode)))
     (cl-letf (((symbol-function 'maduin-review-complete)
                (lambda (sid output)
                  (setq verdict (list sid output))
                  'drift)))
       (maduin-dispatch--complete entry "review-sid")
       (should-not landed)
       (should-not closed)
       (should (equal (car verdict) "review-sid"))
       (should (string-match-p "DRIFT" (cadr verdict)))))))

(ert-deftest maduin-test-dispatch-fail-reviewer-aborts-without-release ()
  "A failed reviewer session releases the hold, not an epic claim."
  :tags '(maduin)
  (maduin-test--with-review-state
   (let* ((released nil)
          (maduin-dispatch--active nil)
          (maduin-dispatch--release-fn (lambda (task) (push task released) t))
          (maduin-dispatch--comment-fn (lambda (_id _text) t))
          (entry (list :handle "review-sid" :seat "odin" :role 'reviewer
                       :task "epic-x" :backend 'opencode)))
     (maduin-review-note-session "review-sid" "epic-x")
     (maduin-dispatch--fail entry "review-sid" 'failed)
     (should-not released)
     (should-not (maduin-review-in-flight-p)))))

(ert-deftest maduin-test-dispatch-ready-holds-fleet-for-rework ()
  "Drift-fix beads dispatch first and hold every ordinary ticket."
  :tags '(maduin)
  (maduin-test--with-review-state
   (let ((dispatched nil))
     (cl-letf (((symbol-function 'maduin-dispatch-implement)
                (lambda (task) (push task dispatched) task)))
       ;; Rework outstanding: only the drift-fix bead is picked up.
       (maduin-dispatch--dispatch-ready '("t1" "drift-1" "t2") '("drift-1"))
       (should (equal (nreverse dispatched) '("drift-1")))
       ;; Review in flight, no rework yet: nothing is consumed.
       (setq dispatched nil)
       (maduin-review-note-session "review-sid" "epic-x")
       (maduin-dispatch--dispatch-ready '("t1" "t2") nil)
       (should-not dispatched)
       ;; Gate clear: ordinary work resumes.
       (maduin-review--drop-session "review-sid")
       (setq dispatched nil)
       (maduin-dispatch--dispatch-ready '("t1" "t2") nil)
       (should (equal (nreverse dispatched) '("t1" "t2")))))))

(ert-deftest maduin-test-dispatch-recover-restricted-while-held ()
  "While the gate holds, only drift-fix orphans are recovered."
  :tags '(maduin)
  (let ((dispatched nil)
        (maduin-dispatch--active nil))
    (cl-letf (((symbol-function 'maduin-dispatch-implement)
               (lambda (task) (push task dispatched) task)))
      (should (= (maduin-dispatch--recover-tasks '("t1" "drift-1") '("drift-1")) 1))
      (should (equal dispatched '("drift-1")))
      (setq dispatched nil)
      (should (= (maduin-dispatch--recover-tasks '("t1" "drift-1") nil) 2)))))

(ert-deftest maduin-test-dispatch-run-loop-holds-on-drift-fix ()
  "The tick reads drift-fix work first and dispatches only it while held."
  :tags '(maduin)
  (maduin-test--with-review-state
   (let ((dispatched nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--draining nil)
         (maduin-dispatch--tick-in-flight nil)
         (maduin-dispatch--drift-fix-async-fn
          (lambda (callback) (funcall callback '("drift-1") t) 'drift-fix))
         (maduin-dispatch--in-progress-async-fn
          (lambda (callback) (funcall callback '("orphan") t) 'in-progress))
         (maduin-dispatch--ready-async-fn
          (lambda (callback) (funcall callback '("t1" "drift-1") t) 'ready))
         (maduin-dispatch--open-epics-async-fn
          (lambda (callback) (funcall callback nil t) 'epics)))
     (cl-letf (((symbol-function 'maduin-dispatch-implement)
                (lambda (task) (push task dispatched) task)))
       (maduin-dispatch-run-loop)
       (should (equal dispatched '("drift-1")))
       (should-not maduin-dispatch--tick-in-flight)))))

;;; 21. Kiro agent definitions and installer contract

(defconst maduin-test--kiro-agent-roles
  '(concierge designer fleet reviewer repairer)
  "Configuration sections backed by checked-in Kiro agents.")

(defun maduin-test--kiro-agent-names ()
  "Return Kiro agent names configured for the production roles."
  (mapcar (lambda (role)
            (alist-get 'agent (cdr (assq role maduin-config))))
          maduin-test--kiro-agent-roles))

(defun maduin-test--agent-prompt-body (path)
  "Return PATH without its YAML frontmatter."
  (with-temp-buffer
    (insert-file-contents path)
    (goto-char (point-min))
    (re-search-forward "^---[ \\t]*$")
    (forward-line 1)
    (re-search-forward "^---[ \\t]*$")
    (forward-line 1)
    (buffer-substring-no-properties (point) (point-max))))

(ert-deftest maduin-test-kiro-agent-files-cover-configured-roles ()
  :tags '(maduin)
  (dolist (name (maduin-test--kiro-agent-names))
    (should (file-exists-p
             (expand-file-name (concat "agents/kiro/" name ".json")
                               maduin-test--dir)))
    (should (file-exists-p
             (expand-file-name (concat "agents/kiro/" name ".prompt.txt")
                               maduin-test--dir)))))

(ert-deftest maduin-test-kiro-agent-json-and-prompt-integrity ()
  :tags '(maduin)
  (dolist (name (maduin-test--kiro-agent-names))
    (let* ((json-path (expand-file-name (concat "agents/kiro/" name ".json")
                                        maduin-test--dir))
           (prompt-path (expand-file-name (concat "agents/kiro/" name ".prompt.txt")
                                          maduin-test--dir))
           (source-path (expand-file-name (concat "agents/" name ".md")
                                          maduin-test--dir))
           (json-object-type 'alist)
           (json-key-type 'symbol)
           (config (json-read-file json-path)))
      (should (equal (alist-get 'name config) name))
      (should (equal (alist-get 'prompt config)
                     (concat "file://~/.kiro/agents/" name ".prompt.txt")))
      (should (file-exists-p prompt-path))
      (should (equal (maduin-test--agent-prompt-body source-path)
                     (with-temp-buffer
                       (insert-file-contents prompt-path)
                       (buffer-string))))
      (should (alist-get 'deniedCommands
                         (alist-get 'execute_bash
                                    (alist-get 'toolsSettings config)))))))

(ert-deftest maduin-test-install-script-wires-kiro-agents ()
  :tags '(maduin)
  (let ((script (expand-file-name "install.sh" maduin-test--dir)))
    (should (zerop (call-process "bash" nil nil nil "-n" script)))
    (with-temp-buffer
      (insert-file-contents script)
      (let ((contents (buffer-string)))
        (should (string-match-p "agents/kiro" contents))
        (should (string-match-p "\\.kiro/agents" contents))
        (should (string-match-p "ln -sf" contents))
        (should (string-match-p "remove_agent_link" contents))))))

;;; 22. backend registry

(defun maduin-test--backend-adapter (&optional record-fn)
  "Return a valid test adapter, optionally sending calls to RECORD-FN."
  (list :executable "sh"
        :run-fn (lambda (workdir model agent plan &optional effort)
                  (when record-fn
                    (funcall record-fn (list :run workdir model agent plan effort)))
                  'run-result)
        :tui-fn (lambda (root model agent prompt &optional effort)
                  (when record-fn
                    (funcall record-fn (list :tui root model agent prompt effort)))
                  'tui-result)
        :complete-p-fn (lambda (sid)
                         (when record-fn (funcall record-fn (list :complete sid)))
                         'complete-result)
        :diff-fn (lambda (sid)
                   (when record-fn (funcall record-fn (list :diff sid)))
                   'diff-result)
        :delete-fn (lambda (sid)
                     (when record-fn (funcall record-fn (list :delete sid)))
                     'delete-result)))

(ert-deftest maduin-test-backend-register-get-and-reject-malformed ()
  :tags '(maduin)
  (let ((maduin-backend-registry (make-hash-table :test #'eq))
        (adapter (maduin-test--backend-adapter)))
    (should (eq (maduin-backend-register 'test adapter) adapter))
    (should (eq (maduin-backend-get 'test) adapter))
    (should-not (maduin-backend-register 'broken '(:executable "broken")))
    (should-not (maduin-backend-get 'broken))
    (should-not (maduin-backend-get 'missing))))

(ert-deftest maduin-test-backend-resolve-priority-and-unknown-selection ()
  :tags '(maduin)
  (let ((maduin-backend-registry (make-hash-table :test #'eq)))
    (maduin-backend-register 'opencode (maduin-test--backend-adapter))
    (maduin-backend-register 'kiro (maduin-test--backend-adapter))
    (cl-letf (((symbol-function 'maduin-config-seat-backend)
               (lambda (_role seat)
                 (pcase seat
                   ("override" 'kiro)
                   ("role-default" 'opencode)
                   ("fallback" nil)
                   ("unknown" 'missing)))))
      (should (eq (maduin-backend-resolve 'implementer "override") 'kiro))
      (should (eq (maduin-backend-resolve 'implementer "role-default") 'opencode))
      (should (eq (maduin-backend-resolve 'implementer "fallback") 'opencode))
      (should-not (maduin-backend-resolve 'implementer "unknown")))))

(ert-deftest maduin-test-backend-missing-executable-does-not-dispatch ()
  :tags '(maduin)
  (let ((maduin-backend-registry (make-hash-table :test #'eq))
        (called nil))
    (maduin-backend-register
     'missing
     (list :executable "not-on-path"
           :run-fn (lambda (&rest _args) (setq called t))
           :tui-fn (lambda (&rest _args) (setq called t))
           :complete-p-fn (lambda (&rest _args) (setq called t))
           :diff-fn (lambda (&rest _args) (setq called t))
           :delete-fn (lambda (&rest _args) (setq called t))))
    (cl-letf (((symbol-function 'executable-find) (lambda (_exe) nil)))
      (should-not (maduin-backend-run 'missing "/work" "model" "agent" "plan")))
    (should-not called)))

(ert-deftest maduin-test-backend-run-forwards-effort ()
  :tags '(maduin)
  (let ((maduin-backend-registry (make-hash-table :test #'eq))
        (call nil))
    (maduin-backend-register
     'test (maduin-test--backend-adapter (lambda (record) (setq call record))))
    (cl-letf (((symbol-function 'executable-find) (lambda (_exe) "/bin/sh")))
      (should (eq (maduin-backend-run 'test "/work" "model" "agent" "plan" "high")
                  'run-result)))
    (should (equal call '(:run "/work" "model" "agent" "plan" "high")))))

(ert-deftest maduin-test-backend-run-nil-effort ()
  :tags '(maduin)
  (let ((maduin-backend-registry (make-hash-table :test #'eq))
        (call nil))
    (maduin-backend-register
     'test (maduin-test--backend-adapter (lambda (record) (setq call record))))
    (cl-letf (((symbol-function 'executable-find) (lambda (_exe) "/bin/sh")))
      (should (eq (maduin-backend-run 'test "/work" "model" "agent" "plan")
                  'run-result)))
    (should (equal call '(:run "/work" "model" "agent" "plan" nil)))))

(ert-deftest maduin-test-backend-tui-forwards-effort ()
  :tags '(maduin)
  (let ((maduin-backend-registry (make-hash-table :test #'eq))
        (call nil))
    (maduin-backend-register
     'test (maduin-test--backend-adapter (lambda (record) (setq call record))))
    (cl-letf (((symbol-function 'executable-find) (lambda (_exe) "/bin/sh")))
      (should (eq (maduin-backend-tui 'test "/root" "model" "prompt" "agent" "high")
                  'tui-result)))
    (should (equal call '(:tui "/root" "model" "agent" "prompt" "high")))))

(ert-deftest maduin-test-backend-unknown-backend-still-nil ()
  :tags '(maduin)
  (let ((maduin-backend-registry (make-hash-table :test #'eq)))
    (should-not (maduin-backend-run 'unknown "/work" "model" "agent" "plan" "high"))))

;;; 23. Kiro backend adapter

(ert-deftest maduin-test-kiro-run-command-nil-effort-unchanged ()
  :tags '(maduin)
  (should (equal (maduin-kiro--run-command
                  "kiro-cli-chat" "/work" "model" "agent" nil "plan")
                 '("kiro-cli-chat" "chat" "--no-interactive"
                   "--agent" "agent" "--model" "model"
                   "--trust-all-tools" "plan"))))

(ert-deftest maduin-test-kiro-run-command-with-effort ()
  :tags '(maduin)
  (should (equal (maduin-kiro--run-command
                  "kiro-cli-chat" "/work" "model" "agent" "medium" "plan")
                 '("kiro-cli-chat" "chat" "--no-interactive"
                   "--agent" "agent" "--model" "model"
                   "--effort" "medium" "--trust-all-tools" "plan"))))

(ert-deftest maduin-test-kiro-effort-valid-p-allowlist ()
  :tags '(maduin)
  (dolist (effort '("low" "medium" "high" "xhigh" "max" "HIGH"))
    (should (maduin-kiro--effort-valid-p effort)))
  (dolist (effort '(nil "" "  " "turbo" "high/max" "very high" 42))
    (should-not (maduin-kiro--effort-valid-p effort))))

(ert-deftest maduin-test-kiro-run-command-invalid-effort-omitted ()
  :tags '(maduin)
  (let ((command (maduin-kiro--run-command
                  "kiro-cli-chat" "/work" "model" "agent" "turbo" "plan")))
    (should-not (member "--effort" command))
    (should (equal command
                   '("kiro-cli-chat" "chat" "--no-interactive"
                     "--agent" "agent" "--model" "model"
                     "--trust-all-tools" "plan")))))

(ert-deftest maduin-test-kiro-run-invalid-model-still-refuses ()
  :tags '(maduin)
  (let ((maduin-kiro--registry (make-hash-table :test #'equal))
        (spawned nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_command) t))
              ((symbol-function 'make-process)
               (lambda (&rest _arguments) (setq spawned t) 'fake-process)))
      (should-not (maduin-kiro-run default-directory "vendor/model"
                                    "slugineer-worker" "plan" "medium")))
    (should-not spawned)))

(ert-deftest maduin-test-kiro-run-uses-required-argv-and-workdir ()
  :tags '(maduin)
  (let ((maduin-kiro--registry (make-hash-table :test #'equal))
        (maduin-kiro--seq 0)
        (workdir (expand-file-name ".." maduin-test--dir))
        command cwd handle)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (_command) t))
                  ((symbol-function 'make-process)
                   (lambda (&rest arguments)
                     (setq command (plist-get arguments :command)
                           cwd default-directory)
                     'fake-process))
                  ((symbol-function 'process-put) (lambda (&rest _arguments) nil)))
          (setq handle (maduin-kiro-run workdir "model" "slugineer-worker" "plan"))
          (should handle)
          (should (equal command
                         '("kiro-cli-chat" "chat" "--no-interactive"
                           "--agent" "slugineer-worker" "--model" "model"
                           "--trust-all-tools" "plan")))
          (should (equal cwd (file-name-as-directory workdir)))
          (should-not (member "--dir" command))
          (should-not (member "--format" command))
          (should-not (member "--auto" command)))
      (let ((entry (and handle (gethash handle maduin-kiro--registry))))
        (when (buffer-live-p (plist-get entry :buffer))
          (kill-buffer (plist-get entry :buffer)))))))

(ert-deftest maduin-test-kiro-run-refuses-invalid-agent-and-model-without-spawn ()
  :tags '(maduin)
  (let ((maduin-kiro--registry (make-hash-table :test #'equal))
        (spawned nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_command) t))
              ((symbol-function 'make-process)
               (lambda (&rest _arguments) (setq spawned t) 'fake-process)))
      (should-not (maduin-kiro-run default-directory "model" "missing-agent" "plan"))
      (should-not (maduin-kiro-run default-directory "vendor/model"
                                   "slugineer-worker" "plan")))
    (should-not spawned)))

(ert-deftest maduin-test-kiro-sentinel-rejects-false-success-and-hooks-once ()
  :tags '(maduin)
  (let* ((maduin-kiro--registry (make-hash-table :test #'equal))
         (maduin-session-on-complete-hook nil)
         (buffer (generate-new-buffer " *maduin-kiro-false-success*"))
         (calls 0)
         (handle "false-success"))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "\e[31mUsage limit reached\e[0m"))
          (puthash handle (list :process 'fake-process :buffer buffer
                                :workdir default-directory :status 'running :done nil)
                   maduin-kiro--registry)
          (add-hook 'maduin-session-on-complete-hook
                    (lambda (_handle _status) (setq calls (1+ calls))))
          (cl-letf (((symbol-function 'process-status) (lambda (_process) 'exit))
                    ((symbol-function 'process-exit-status) (lambda (_process) 0))
                    ((symbol-function 'process-get)
                     (lambda (_process property)
                       (and (eq property 'maduin-kiro-handle) handle))))
            (maduin-kiro--run-sentinel 'fake-process "finished\n")
            (maduin-kiro--run-sentinel 'fake-process "finished\n"))
          (should (eq (maduin-kiro-complete-p handle) 'limited))
          (should (= calls 1))
          (should-not (string-match-p "\e" (plist-get (gethash handle maduin-kiro--registry)
                                                        :output))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest maduin-test-kiro-diff-includes-unstaged-staged-and-untracked ()
  :tags '(maduin)
  (let ((maduin-kiro--registry (make-hash-table :test #'equal))
        (handle "diff")
        calls)
    (puthash handle (list :workdir "/work/" :status 'completed :done t)
             maduin-kiro--registry)
    (cl-letf (((symbol-function 'maduin-kiro--git)
               (lambda (workdir &rest arguments)
                 (push (cons workdir arguments) calls)
                 (cond
                  ((equal arguments '("diff" "--no-ext-diff")) '(0 . "unstaged\n"))
                  ((equal arguments '("diff" "--cached" "--no-ext-diff")) '(0 . "staged\n"))
                  ((equal arguments '("ls-files" "--others" "--exclude-standard" "-z"))
                   '(0 . "new.el\0"))
                  ((equal arguments '("diff" "--no-index" "--" "/dev/null" "new.el"))
                   '(1 . "untracked\n"))))))
      (should (equal (maduin-kiro-diff handle) "unstaged\nstaged\nuntracked\n"))
      (should (member '("/work/" . ("diff" "--no-index" "--" "/dev/null" "new.el")) calls)))))

(ert-deftest maduin-test-kiro-delete-kills-local-state-only ()
  :tags '(maduin)
  (let* ((maduin-kiro--registry (make-hash-table :test #'equal))
         (handle "delete")
         (buffer (generate-new-buffer " *maduin-kiro-delete*"))
         (killed nil))
    (puthash handle (list :process 'fake-process :buffer buffer :workdir "/work/"
                          :status 'running :done nil)
             maduin-kiro--registry)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
              ((symbol-function 'delete-process)
               (lambda (_process) (setq killed t))))
      (should (maduin-kiro-delete handle)))
    (should killed)
    (should-not (gethash handle maduin-kiro--registry))
    (should-not (buffer-live-p buffer))))

;;; 24. backend launch routing

(ert-deftest maduin-test-dispatch-seat-backend-routing-records-backend ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (seen nil)
         (maduin-config (copy-tree maduin-config))
         (maduin-dispatch--active nil)
         (maduin-dispatch--claim-fn (lambda (_task) t))
         (maduin-dispatch--show-fn (lambda (_task) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_seat) dir))
         (maduin-dispatch--session-run-fn
          (lambda (workdir model agent plan backend &optional _effort)
            (setq seen (list workdir model agent plan backend))
            "kiro-1")))
    (unwind-protect
        (progn
          (maduin-config-set-seat-backend 'implementer "ifrit" 'kiro)
          (should (equal (maduin-dispatch-implement "t1") "kiro-1"))
          (should (equal (nth 1 seen) "gpt-5.6-terra"))
          (should (eq (nth 4 seen) 'kiro))
          (should (eq (plist-get (car maduin-dispatch--active) :backend) 'kiro)))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-sticky-backend-for-diff-and-delete ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (calls nil)
         (maduin-config (copy-tree maduin-config))
         (maduin-dispatch--active nil)
         (maduin-dispatch--claim-fn (lambda (_task) t))
         (maduin-dispatch--show-fn (lambda (_task) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_seat) dir))
         (maduin-dispatch--session-run-fn (lambda (&rest _args) "opencode-1"))
         (maduin-dispatch--diff-fn
          (lambda (backend sid) (push (list :diff backend sid) calls) nil))
         (maduin-dispatch--session-delete-fn
          (lambda (backend sid) (push (list :delete backend sid) calls) t))
         (maduin-dispatch--land-fn (lambda (_seat &optional _stamp) t))
         (maduin-dispatch--landed-fn (lambda (_seat) t))
         (maduin-dispatch--close-fn (lambda (&rest _args) t)))
    (unwind-protect
        (progn
          (maduin-dispatch-implement "t1")
          (maduin-config-set-seat-backend 'implementer "ifrit" 'kiro)
          (maduin-dispatch--on-complete "opencode-1" 'completed)
          (should (equal (nreverse calls)
                         '((:diff opencode "opencode-1")
                           (:delete opencode "opencode-1")))))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-spawn-failure-releases-claim ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (released nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--claim-fn (lambda (_task) t))
         (maduin-dispatch--show-fn (lambda (_task) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_seat) dir))
         (maduin-dispatch--session-run-fn (lambda (&rest _args) nil))
         (maduin-dispatch--release-fn (lambda (task) (setq released task) t))
         (maduin-dispatch--comment-fn (lambda (&rest _args) t)))
    (unwind-protect
        (progn
          (should-not (maduin-dispatch-implement "t1"))
          (should (equal released "t1"))
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

(ert-deftest maduin-test-dispatch-format-kiro-diff-string ()
  :tags '(maduin)
  (should (equal (maduin-dispatch--format-diffs "diff --git a/a.el b/a.el\n")
                 "diff --git a/a.el b/a.el\n")))

(ert-deftest maduin-test-terminal-kiro-dismiss-never-exports-opencode ()
  :tags '(maduin)
  (let* ((saved nil)
         (deleted nil)
         (buf nil)
         (maduin-config (copy-tree maduin-config))
         (maduin-terminal--tui-fn
          (lambda (backend root model agent prompt)
            (should (eq backend 'kiro))
            (should (stringp root))
            (should (equal model "gpt-5.6-terra"))
            (should (equal agent "slugineer-planner-concierge"))
            (should (stringp prompt))
            "kiro-1"))
         (maduin-terminal--delete-fn
          (lambda (backend sid) (setq deleted (list backend sid)) t)))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-backend-resolve)
                   (lambda (_role _seat) 'kiro))
                  ((symbol-function 'maduin-config-seat-model)
                   (lambda (_role _seat _backend) "gpt-5.6-terra"))
                  ((symbol-function 'maduin-terminal--write-handoff)
                   (lambda (_seat note _root) (setq saved note) t)))
          (setq buf (maduin-terminal-open "alexander" 'concierge "ignored"))
          (should (buffer-live-p buf))
          (should (string-match-p "No conversation export"
                                  (maduin-terminal-dismiss "alexander")))
          (should (string-match-p "No conversation export" saved))
          (should (equal deleted '(kiro "kiro-1"))))
      (when (and buf (buffer-live-p buf))
        (kill-buffer buf)))))

;;; 8g. cockpit-backend

(ert-deftest maduin-test-cockpit-backend-active-and-idle-values ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config))
        (maduin-dispatch--active
         (list (list :handle "s-1" :seat "ifrit" :role 'implementer
                     :backend 'kiro))))
    ;; The active value is frozen at launch, despite current configuration.
    (maduin-config-set-seat-backend 'implementer "shiva" 'kiro)
    (should (eq (plist-get (maduin-cockpit--seat-status "ifrit") :backend)
                'kiro))
    (should (eq (plist-get (maduin-cockpit--seat-status "shiva") :backend)
                'kiro))
    (let ((ifrit-row (assoc "ifrit" (maduin-cockpit--rows)))
          (shiva-row (assoc "shiva" (maduin-cockpit--rows))))
      (should (equal (aref (cadr ifrit-row) 5) "kiro"))
      (should (equal (aref (cadr shiva-row) 5) "kiro")))))

(ert-deftest maduin-test-cockpit-toggle-backend-cycles-runtime-only ()
  :tags '(maduin)
  (let* ((maduin-config (copy-tree maduin-config))
         (maduin-dispatch--active nil)
         (before-file (with-temp-buffer
                        (insert-file-contents maduin-config--file)
                        (buffer-string)))
         (refreshes 0)
         (buf (generate-new-buffer " *maduin-cockpit-backend-test*")))
    (unwind-protect
        (with-current-buffer buf
          (tabulated-list-mode)
          (let ((inhibit-read-only t))
            (insert "ifrit")
            (put-text-property (point-min) (point-max)
                               'tabulated-list-id "ifrit"))
          (goto-char (point-min))
          (cl-letf (((symbol-function 'maduin-cockpit-refresh)
                     (lambda () (cl-incf refreshes))))
            (maduin-cockpit--toggle-backend)
            (should (eq (maduin-config-seat-backend 'implementer "ifrit") 'kiro))
            (maduin-cockpit--toggle-backend)
            (should (eq (maduin-config-seat-backend 'implementer "ifrit")
                        'opencode))
            (should (= refreshes 2))))
      (kill-buffer buf))
    (should (equal (with-temp-buffer
                     (insert-file-contents maduin-config--file)
                     (buffer-string))
                   before-file))))

(ert-deftest maduin-test-cockpit-toggle-backend-rejects-invalid-or-active-seat ()
  :tags '(maduin)
  (let* ((maduin-config (copy-tree maduin-config))
         (before (copy-tree maduin-config)))
    (dolist (id '(nil "unknown"))
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () id)))
        (should-error (maduin-cockpit--toggle-backend) :type 'user-error)
        (should (equal maduin-config before))))
    (let ((maduin-dispatch--active
           (list (list :handle "s-1" :seat "ifrit" :role 'implementer
                       :backend 'opencode))))
      (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () "ifrit")))
        (should-error (maduin-cockpit--toggle-backend) :type 'user-error)
        (should (equal maduin-config before))))))

(ert-deftest maduin-test-cockpit-backend-binding-mirrors-evil-states ()
  :tags '(maduin)
  (should (eq (lookup-key maduin-cockpit-map (kbd "b"))
              'maduin-cockpit--toggle-backend))
  (let ((recorded nil))
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature &optional _subfeature) (eq feature 'evil)))
              ((symbol-function 'fboundp)
               (lambda (function) (eq function 'evil-define-key*)))
              ((symbol-function 'evil-define-key*)
               (lambda (state _map key definition)
                 (push (list state key definition) recorded))))
      (maduin-cockpit--evil-setup)
      (should (member (list 'normal (kbd "b")
                            'maduin-cockpit--toggle-backend)
                      recorded))
      (should (member (list 'motion (kbd "b")
                            'maduin-cockpit--toggle-backend)
                      recorded)))))

(ert-deftest maduin-test-dispatch-kiro-fallbacks-cover-every-role ()
  :tags '(maduin)
  (dolist (expectation
           '((concierge "gpt-5.6-terra")
             (designer "gpt-5.6-terra")
             (implementer "gpt-5.6-terra")
             (reviewer "gpt-5.6-terra")
             (repairer "gpt-5.6-terra")))
    (pcase-let ((`(,role ,model) expectation))
      (should (equal (maduin-dispatch--seat-fallback role 'kiro) model))))
  (should (equal (maduin-dispatch--seat-fallback 'implementer 'opencode)
                 "opencode-go/deepseek-v4-flash"))
  (should-not (maduin-dispatch--seat-fallback 'designer 'opencode)))

(ert-deftest maduin-test-kiro-limit-patterns-cover-usage-and-credit ()
  :tags '(maduin)
  (should (maduin-kiro--limited-tail-p "Usage limit reached"))
  (should (maduin-kiro--limited-tail-p "Credit limit exceeded"))
  (should-not (maduin-kiro--limited-tail-p "authentication failed")))

(ert-deftest maduin-test-dispatch-kiro-limited-retry-sticky-and-bounded ()
  :tags '(maduin)
  (let* ((dir (maduin-test--temp-dir))
         (runs nil)
         (claims 0)
         (released nil)
         (maduin-config (copy-tree maduin-config))
         (maduin-dispatch--active nil)
         (maduin-dispatch--session-run-fn
          (lambda (_workdir model _agent _plan backend &optional _effort)
            (push (list backend model) runs)
            (format "kiro-%d" (length runs))))
         (maduin-dispatch--claim-fn (lambda (_task) (cl-incf claims) t))
         (maduin-dispatch--release-fn (lambda (task) (setq released task) t))
         (maduin-dispatch--show-fn (lambda (_task) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_seat) dir))
         (maduin-dispatch--comment-fn (lambda (&rest _args) t))
         (maduin-dispatch--session-delete-fn (lambda (&rest _args) t)))
    (unwind-protect
        (progn
          (maduin-config-set-seat-backend 'implementer "ifrit" 'kiro)
          (should (equal (maduin-dispatch-implement "t-kiro") "kiro-1"))
          (maduin-config-set-seat-backend 'implementer "ifrit" 'opencode)
          (maduin-dispatch--on-complete "kiro-1" 'limited)
          (should (equal (reverse runs)
                         '((kiro "gpt-5.6-terra")
                           (kiro "gpt-5.6-terra"))))
          (should (= claims 1))
          (should-not released)
          (should (= (length maduin-dispatch--active) 1))
          (maduin-dispatch--on-complete "kiro-2" 'limited)
          (should (= (length runs) 2))
          (should (equal released "t-kiro"))
          (should-not maduin-dispatch--active))
      (delete-directory dir t))))

(ert-deftest maduin-test-backend-resolve-uses-concrete-config-precedence ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config))
        (maduin-backend-registry (make-hash-table :test #'eq)))
    (unwind-protect
        (progn
          (maduin-backend-register 'opencode (maduin-test--backend-adapter))
          (maduin-backend-register 'kiro (maduin-test--backend-adapter))
          (setcdr (assq 'backend (cdr (assq 'fleet maduin-config))) 'kiro)
          (maduin-config-set-seat-backend 'implementer "ifrit" 'opencode)
          (should (eq (maduin-backend-resolve 'implementer "ifrit") 'opencode))
          (should (eq (maduin-backend-resolve 'implementer "shiva") 'kiro))
          (setcdr (assq 'backend (cdr (assq 'fleet maduin-config))) 'invalid)
          (should (eq (maduin-backend-resolve 'implementer "shiva") 'opencode)))
      (clrhash maduin-backend-registry))))

(ert-deftest maduin-test-session-opencode-adapter-accepts-optional-effort ()
  :tags '(maduin)
  (let ((maduin-backend-registry (make-hash-table :test #'eq))
        (received nil))
    (unwind-protect
        (progn
          (maduin-backend-register
           'opencode
           (list :executable "opencode"
                 :run-fn #'maduin-session--opencode-run
                 :tui-fn #'maduin-session--opencode-tui
                 :complete-p-fn #'maduin-session-complete-p
                 :diff-fn #'maduin-session-diff
                 :delete-fn #'maduin-session-delete))
          (cl-letf (((symbol-function 'maduin-session--opencode-run)
                     (lambda (&rest args) (setq received args) 'handle)))
            (should (eq (maduin-backend-run 'opencode "/work" "model"
                                            "agent" "plan" "high")
                        'handle))
            (should (equal received '("/work" "model" "agent" "plan" "high")))))
      (clrhash maduin-backend-registry))))

(ert-deftest maduin-test-kiro-completion-statuses-remain-local ()
  :tags '(maduin)
  (let ((maduin-kiro--registry (make-hash-table :test #'equal)))
    (puthash "running" (list :process 'process :status 'running :done nil)
             maduin-kiro--registry)
    (puthash "limited" (list :process 'process :status 'limited :done t)
             maduin-kiro--registry)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t)))
      (should (eq (maduin-kiro-complete-p "running") 'running)))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) nil)))
      (should (eq (maduin-kiro-complete-p "running") 'failed)))
    (should (eq (maduin-kiro-complete-p "limited") 'limited))
    (should (eq (maduin-kiro-complete-p "unknown") 'failed))))

;;; Commit provenance stamps

(ert-deftest maduin-test-stamp-trailers-order ()
  :tags '(maduin)
  (let ((trailers
         (maduin-stamp-trailers
          '(:model "gpt-5.6-luna" :backend kiro :difficulty low
            :effort "medium" :agent "slugineer-worker" :seat "ifrit"
            :task "maduin-2nv" :harness "maduin 0.3.0" :rev "5facf72"))))
    (should (= (length trailers) 9))
    (should (equal (mapcar #'car trailers)
                   '("Maduin-Model" "Maduin-Backend" "Maduin-Difficulty"
                     "Maduin-Effort" "Maduin-Agent" "Maduin-Seat"
                     "Maduin-Task" "Maduin-Harness"
                     "Maduin-Harness-Rev")))
    (should (equal (caar trailers) "Maduin-Model"))
    (should (equal (caar (last trailers)) "Maduin-Harness-Rev"))))

(ert-deftest maduin-test-stamp-trailers-omits-empty ()
  :tags '(maduin)
  (let ((trailers (maduin-stamp-trailers
                   '(:model "gpt-5.6-luna" :backend nil :difficulty ""
                     :effort "  "))))
    (should (equal trailers '(("Maduin-Model" . "gpt-5.6-luna"))))
    (should-not (maduin-stamp-trailers nil))
    (should-not (maduin-stamp-trailers "not a plist"))
    (should-not (seq-some (lambda (trailer) (string-empty-p (cdr trailer)))
                          trailers))))

(ert-deftest maduin-test-stamp-trailers-sanitizes-injection ()
  :tags '(maduin)
  (let* ((trailers (maduin-stamp-trailers
                    '(:model "a\nMaduin-Task: forged")))
         (value (cdar trailers)))
    (should (equal (mapcar #'car trailers) '("Maduin-Model")))
    (should-not (string-match-p "[\n\r:]" value))
    (should (equal value "a Maduin-Task forged"))))

(ert-deftest maduin-test-stamp-trailers-accepts-symbols ()
  :tags '(maduin)
  (should (equal (maduin-stamp-trailers '(:backend kiro :difficulty low))
                 '(("Maduin-Backend" . "kiro")
                   ("Maduin-Difficulty" . "low")))))

(ert-deftest maduin-test-stamp-format-summary ()
  :tags '(maduin)
  (should
   (equal
    (maduin-stamp-format
     '(("Maduin-Model" . "gpt-5.6-luna")
       ("Maduin-Backend" . "kiro")
       ("Maduin-Difficulty" . "low")
       ("Maduin-Effort" . "medium")
       ("Maduin-Harness" . "maduin 0.3.0")
       ("Maduin-Harness-Rev" . "5facf72")))
    "gpt-5.6-luna/kiro/low/medium @ maduin 0.3.0 (5facf72)")))

(ert-deftest maduin-test-stamp-format-partial ()
  :tags '(maduin)
  (should (equal (maduin-stamp-format
                  '(("Maduin-Model" . "gpt-5.6-luna")))
                 "gpt-5.6-luna"))
  (should (equal (maduin-stamp-format nil) "unstamped")))

(ert-deftest maduin-test-stamp-exec-command-quotes-values ()
  :tags '(maduin)
  (let* ((trailer "Maduin-Harness=maduin 0.3.0")
         (command (maduin-stamp-exec-command
                   `(("Maduin-Harness" . "maduin 0.3.0")))))
    (should (string-prefix-p "git " command))
    (should (string-match-p
             (regexp-quote (concat "--trailer "
                                   (shell-quote-argument trailer)))
             command))))

(ert-deftest maduin-test-stamp-exec-command-sets-ifexists ()
  :tags '(maduin)
  (let ((command (maduin-stamp-exec-command
                  '(("Maduin-Model" . "gpt-5.6-luna")
                    ("Maduin-Backend" . "kiro")))))
    (should (string-match-p "-c trailer.ifexists=replaceIfDifferent" command))
    (should (string-match-p "commit --amend --no-edit" command))
    (should (= 2 (1- (length (split-string command "--trailer " t)))))))

(ert-deftest maduin-test-stamp-exec-command-empty-nil ()
  :tags '(maduin)
  (should-not (maduin-stamp-exec-command nil))
  (should-not (maduin-stamp-exec-command '()))
  (should-not (maduin-stamp-exec-command '(("" . "value")
                                             ("Maduin-Model" . "")))))

(ert-deftest maduin-test-stamp-parse-roundtrip ()
  :tags '(maduin)
  (let* ((trailers (maduin-stamp-trailers
                    '(:model "gpt-5.6-luna" :backend kiro :difficulty low
                      :effort "medium" :harness "maduin 0.3.0" :rev "5facf72")))
         (message (concat "subject\n\n"
                          (mapconcat (lambda (trailer)
                                       (format "%s: %s" (car trailer) (cdr trailer)))
                                     trailers "\n")))
         (parsed (maduin-stamp-parse message)))
    (should (equal parsed trailers))
    (should (equal (maduin-stamp-format parsed)
                   "gpt-5.6-luna/kiro/low/medium @ maduin 0.3.0 (5facf72)"))))

(ert-deftest maduin-test-stamp-parse-ignores-foreign ()
  :tags '(maduin)
  (should (equal
           (maduin-stamp-parse
            (concat "Subject\n\nBody mentions Maduin-Model: not a trailer.\n"
                    "Maduin-Model: gpt-5.6-luna\n"
                    "Signed-off-by: A Person <a@example.test>\n"
                    "Co-authored-by: Another Person <b@example.test>\n"
                    "Maduin-Bogus: ignored\n"))
           '(("Maduin-Model" . "gpt-5.6-luna")))))

(ert-deftest maduin-test-stamp-parse-empty ()
  :tags '(maduin)
  (should-not (maduin-stamp-parse nil))
  (should-not (maduin-stamp-parse ""))
  (should-not (maduin-stamp-parse 42)))

(ert-deftest maduin-test-dispatch-stamp-for-fields ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config))
        (maduin-pipeline--main-root-fn (lambda () "/repo"))
        (maduin-pipeline--git-output-fn
         (lambda (_root &rest _args) '(0 . "5facf72\n"))))
    (let ((stamp (maduin-dispatch--stamp-for
                  '(:role implementer :model "gpt-5.6-luna" :backend kiro
                    :difficulty low :effort "medium" :seat "ifrit"
                    :task "maduin-2nv.12"))))
      (should (equal stamp
                     '(:model "gpt-5.6-luna" :backend kiro :difficulty low
                       :effort "medium" :agent "slugineer-worker"
                       :seat "ifrit" :task "maduin-2nv.12"
                       :harness "maduin 0.3.0" :rev "5facf72"))))))

(ert-deftest maduin-test-dispatch-stamp-for-tolerates-missing ()
  :tags '(maduin)
  (let ((maduin-pipeline--main-root-fn (lambda () "/repo"))
        (maduin-pipeline--git-output-fn
         (lambda (&rest _args) (error "git unavailable"))))
    (let ((stamp (maduin-dispatch--stamp-for
                  '(:role implementer :model "model" :backend kiro
                    :seat "ifrit" :task "task-1"))))
      (should (equal (plist-get stamp :difficulty) nil))
      (should (equal (plist-get stamp :effort) nil))
      (should (equal (plist-get stamp :rev) nil)))))

(ert-deftest maduin-test-dispatch-complete-passes-stamp-to-land ()
  :tags '(maduin)
  (let* ((land-call nil)
        (maduin-pipeline--main-root-fn (lambda () "/repo"))
        (maduin-pipeline--git-output-fn
         (lambda (_root &rest _args) '(0 . "5facf72\n")))
        (maduin-dispatch--diff-fn (lambda (_backend _sid) nil))
        (maduin-dispatch--land-fn
         (lambda (seat &optional stamp) (setq land-call (list seat stamp)) t))
        (maduin-dispatch--landed-fn (lambda (_seat) t))
        (maduin-dispatch--close-fn (lambda (&rest _args) t))
        (maduin-dispatch--workdir-fn (lambda (_seat) "/work")))
    (maduin-dispatch--complete
     '(:role implementer :model "gpt-5.6-luna" :backend kiro
       :difficulty low :effort "medium" :seat "ifrit" :task "task-1")
     "session-1")
    (should (equal (car land-call) "ifrit"))
    (let ((stamp (cadr land-call)))
      (should (equal (plist-get stamp :model) "gpt-5.6-luna"))
      (should (eq (plist-get stamp :backend) 'kiro))
      (should (eq (plist-get stamp :difficulty) 'low))
      (should (equal (plist-get stamp :effort) "medium")))))

(ert-deftest maduin-test-dispatch-complete-close-output-has-provenance ()
  :tags '(maduin)
  (let* ((close-output nil)
        (maduin-pipeline--main-root-fn (lambda () "/repo"))
        (maduin-pipeline--git-output-fn
         (lambda (_root &rest _args) '(0 . "5facf72\n")))
        (maduin-dispatch--diff-fn (lambda (_backend _sid) "unchanged diff"))
        (maduin-dispatch--land-fn (lambda (_seat &optional _stamp) t))
        (maduin-dispatch--landed-fn (lambda (_seat) t))
        (maduin-dispatch--close-fn
         (lambda (_task output &optional _dir) (setq close-output output) t))
        (maduin-dispatch--workdir-fn (lambda (_seat) "/work")))
    (maduin-dispatch--complete
     '(:role implementer :model "gpt-5.6-luna" :backend kiro
       :difficulty low :effort "medium" :seat "ifrit" :task "task-1")
     "session-1")
    (should (equal close-output
                   "unchanged diff\nprovenance: gpt-5.6-luna/kiro/low/medium @ maduin 0.3.0 (5facf72)"))))

(ert-deftest maduin-test-dispatch-complete-conflict-unchanged ()
  :tags '(maduin)
  (let* ((comment nil)
        (repair nil)
        (closed nil)
        (maduin-pipeline--main-root-fn (lambda () "/repo"))
        (maduin-pipeline--git-output-fn
         (lambda (_root &rest _args) '(0 . "5facf72\n")))
        (maduin-dispatch--diff-fn (lambda (_backend _sid) nil))
        (maduin-dispatch--land-fn (lambda (_seat &optional _stamp) 'conflict))
        (maduin-dispatch--comment-fn
         (lambda (task text) (setq comment (cons task text)) t))
        (maduin-dispatch--close-fn (lambda (&rest _args) (setq closed t))))
    (cl-letf (((symbol-function 'maduin-dispatch-repair)
               (lambda (seat task) (setq repair (list seat task)) "repair-1")))
      (maduin-dispatch--complete
       '(:role implementer :model "gpt-5.6-luna" :backend kiro
         :difficulty low :effort "medium" :seat "ifrit" :task "task-1")
       "session-1"))
    (should (equal comment '("task-1" . "merge conflict — repairer dispatched")))
    (should (equal repair '("ifrit" "task-1")))
    (should-not closed)))

(provide 'maduin-test)

;;; maduin-test.el ends here


;;; 8h. cockpit-config

(defun maduin-test--cockpit-config-row (section key)
  "Return config panel row for SECTION and KEY."
  (cl-find-if (lambda (row)
                (and (eq (plist-get row :section) section)
                     (eq (plist-get row :key) key)))
              (apply #'append (mapcar #'cdr (maduin-cockpit-config--rows)))))

(ert-deftest maduin-test-cockpit-config-rows-group-every-schema-option ()
  :tags '(maduin)
  (let* ((groups (maduin-cockpit-config--rows))
         (rows (apply #'append (mapcar #'cdr groups))))
    (should (equal (mapcar #'car groups)
                   '(harness crew concierge designer fleet reviewer repairer welfare workspaces)))
    (should (= (length rows) (length (maduin-config-options))))
    (should (equal (mapcar (lambda (row) (plist-get row :key))
                           (cdr (assq 'harness groups)))
                   '(name version)))))

(ert-deftest maduin-test-cockpit-config-read-dispatches-by-type ()
  :tags '(maduin)
  (let ((integer (maduin-test--cockpit-config-row 'fleet 'poll-interval))
        (boolean (maduin-test--cockpit-config-row 'reviewer 'enabled))
        (symbol (maduin-test--cockpit-config-row 'fleet 'backend))
        (string (maduin-test--cockpit-config-row 'fleet 'agent)))
    (cl-letf (((symbol-function 'read-number) (lambda (&rest _args) 41))
              ((symbol-function 'y-or-n-p) (lambda (&rest _args) t))
              ((symbol-function 'completing-read) (lambda (&rest _args) "kiro"))
              ((symbol-function 'read-string) (lambda (&rest _args) "worker-next")))
      (should (= (maduin-cockpit-config--read integer) 41))
      (should (eq (maduin-cockpit-config--read boolean) t))
      (should (eq (maduin-cockpit-config--read symbol) 'kiro))
      (should (equal (maduin-cockpit-config--read string) "worker-next")))))

(ert-deftest maduin-test-cockpit-config-apply-refreshes-runtime-only ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config))
        (row (maduin-test--cockpit-config-row 'fleet 'poll-interval))
        (refreshes 0)
        (message-text nil))
    (cl-letf (((symbol-function 'maduin-cockpit-refresh)
               (lambda () (cl-incf refreshes)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text (apply #'format format-string args)))))
      (should (= (maduin-cockpit-config--apply row 41) 41))
      (should (= (maduin-config-option 'fleet 'poll-interval) 41))
      (should (= refreshes 1))
      (should (string-match-p "runtime only" message-text))
      (should (string-match-p "harness/config.el" message-text)))))

(ert-deftest maduin-test-cockpit-config-apply-refreshes-cockpit-buffer ()
  :tags '(maduin)
  (let* ((maduin-config (copy-tree maduin-config))
         (maduin-cockpit-buffer-name " *maduin-config-refresh*")
         (row (maduin-test--cockpit-config-row 'fleet 'backend))
         (buf (generate-new-buffer maduin-cockpit-buffer-name))
         (refresh-buffer nil))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-cockpit-refresh)
                   (lambda () (setq refresh-buffer (current-buffer))))
                  ((symbol-function 'message) #'ignore))
          (with-current-buffer buf
            (setq-local maduin-cockpit--render-signature 'stale))
          (maduin-cockpit-config--apply row 'kiro)
          (should (eq refresh-buffer buf))
          (with-current-buffer buf
            (should-not maduin-cockpit--render-signature)))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-config-crew-backend-display-updates ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config))
        (row (maduin-test--cockpit-config-row 'crew 'backend)))
    (cl-letf (((symbol-function 'maduin-cockpit-refresh) #'ignore)
              ((symbol-function 'message) #'ignore))
      (maduin-cockpit-config--apply row 'kiro))
    (should (eq (maduin-config-crew-backend) 'kiro))
    (should (string-match-p "crew/backend.*(kiro)"
                            (maduin-cockpit-config--display
                             (maduin-test--cockpit-config-row 'crew 'backend))))))

(ert-deftest maduin-test-cockpit-config-apply-rejects-invalid-without-mutation ()
  :tags '(maduin)
  (let* ((maduin-config (copy-tree maduin-config))
         (before (copy-tree maduin-config))
         (row (maduin-test--cockpit-config-row 'fleet 'poll-interval))
         (refreshes 0))
    (cl-letf (((symbol-function 'maduin-cockpit-refresh)
               (lambda () (cl-incf refreshes))))
      (should-error (maduin-cockpit-config--apply row "41") :type 'user-error)
      (should (equal maduin-config before))
      (should (= refreshes 0)))))

(ert-deftest maduin-test-cockpit-config-harness-identity-is-read-only ()
  :tags '(maduin)
  (dolist (key '(name version))
    (let ((row (maduin-test--cockpit-config-row 'harness key)))
      (should-error (maduin-cockpit-config--apply row "changed")
                    :type 'user-error))))

(ert-deftest maduin-test-cockpit-config-fallback-without-transient ()
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config))
        (refreshes 0)
        (real-fboundp (symbol-function 'fboundp)))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (symbol)
                 (if (memq symbol '(transient-setup transient-define-prefix))
                     nil
                   (funcall real-fboundp symbol))))
              ((symbol-function 'completing-read)
               (lambda (&rest _args)
                 (maduin-cockpit-config--display
                  (maduin-test--cockpit-config-row 'fleet 'poll-interval))))
              ((symbol-function 'read-number) (lambda (&rest _args) 47))
              ((symbol-function 'maduin-cockpit-refresh)
               (lambda () (cl-incf refreshes))))
      (should (= (maduin-cockpit-config) 47))
      (should (= (maduin-config-option 'fleet 'poll-interval) 47))
      (should (= refreshes 1)))))

(ert-deftest maduin-test-cockpit-config-binding-hint-and-evil-mirror ()
  :tags '(maduin)
  (should (eq (lookup-key maduin-cockpit-map (kbd "c"))
              'maduin-cockpit-config))
  (should-not (member "c" maduin-cockpit--evil-suppress-keys))
  (should (equal (cdr (assq 'maduin-cockpit-config maduin-cockpit-bar--labels))
                 "config"))
  (should (memq 'maduin-cockpit-config maduin--feature-list))
  (let ((recorded nil))
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature &optional _subfeature) (eq feature 'evil)))
              ((symbol-function 'fboundp)
               (lambda (function) (eq function 'evil-define-key*)))
              ((symbol-function 'evil-define-key*)
               (lambda (state _map key definition)
                 (push (list state key definition) recorded))))
      (maduin-cockpit--evil-setup)
      (should (member (list 'normal (kbd "c") 'maduin-cockpit-config) recorded))
      (should (member (list 'motion (kbd "c") 'maduin-cockpit-config) recorded)))))


;;; 22. cockpit visual polish

(ert-deftest maduin-test-cockpit-visual-faces-palette-and-adaptation ()
  :tags '(maduin)
  (let ((text-faces '(maduin-cockpit-role maduin-cockpit-backend
                      maduin-cockpit-task-id maduin-cockpit-task-title
                      maduin-cockpit-placeholder maduin-cockpit-header)))
    (dolist (face (append '(maduin-cockpit-state-failed) text-faces))
      (should (facep face))
      (dolist (palette '(dark light))
        (should (assq face
                      (cdr (assq palette maduin-cockpit-face--palette))))))
    (dolist (face text-faces)
      (should-not (memq face maduin-cockpit-face--pill-faces)))
    (dolist (dark '(t nil))
      (cl-letf (((symbol-function 'maduin-cockpit-face-dark-p)
                 (lambda () dark)))
        (should (maduin-cockpit-face-adapt))
        (should (maduin-cockpit-face-adapt))))))

(ert-deftest maduin-test-cockpit-visual-failed-state-and-glyph-fallback ()
  :tags '(maduin)
  (should (eq (maduin-cockpit-state-face 'failed)
              'maduin-cockpit-state-failed))
  (cl-letf (((symbol-function 'char-displayable-p) (lambda (_char) t)))
    (should (equal (maduin-cockpit--glyph 'queued) "◐")))
  (cl-letf (((symbol-function 'char-displayable-p) (lambda (_char) nil)))
    (should (equal (maduin-cockpit--glyph 'queued) "q"))
    (should (equal (maduin-cockpit--glyph 'fleet-busy) "#"))))

(ert-deftest maduin-test-cockpit-visual-cell-faces-and-task-truncation ()
  :tags '(maduin)
  (let ((placeholder (maduin-cockpit--placeholder))
        (task (maduin-cockpit--task-string
               '(:task-id "maduin-visual-task"
                 :task-title "A deliberately long task title that must truncate"))))
    (should (eq (get-text-property 0 'face placeholder)
                'maduin-cockpit-placeholder))
    (should (eq (get-text-property 0 'face task)
                'maduin-cockpit-task-id))
    (let ((title-pos (+ (string-match " — " task) 3)))
      (should (eq (get-text-property title-pos 'face task)
                  'maduin-cockpit-task-title)))
    (should (<= (string-width task) 30))
    (should (string-suffix-p "…" task)))
  (cl-letf (((symbol-function 'maduin-cockpit--seats)
             (lambda () '(("ifrit" . "implementer"))))
            ((symbol-function 'maduin-cockpit--seat-status)
             (lambda (_seat)
               '(:role implementer :status idle :backend opencode))))
    (let* ((row (car (maduin-cockpit--rows)))
           (cells (cadr row)))
      (should (eq (get-text-property 0 'face (aref cells 1))
                  'maduin-cockpit-role))
      (should (eq (get-text-property 0 'face (aref cells 5))
                  'maduin-cockpit-backend))
      (dolist (column '(3 4 6 7))
        (should (eq (get-text-property 0 'face (aref cells column))
                    'maduin-cockpit-placeholder))))))

(ert-deftest maduin-test-cockpit-visual-header-and-role-grouping ()
  :tags '(maduin)
  (cl-letf (((symbol-function 'maduin-pipeline-status)
             (lambda () '(:queued 0 :active 0 :completed 0 :blocked 0
                          :fleet-free 0 :fleet-busy 0))))
    (should (eq (get-text-property 0 'face (maduin-cockpit--header-string))
                'maduin-cockpit-header)))
  (cl-letf (((symbol-function 'maduin-cockpit--seats)
             (lambda () '(("ifrit" . "implementer")
                          ("alexander" . "concierge")
                          ("ramuh" . "designer")
                          ("shiva" . "implementer"))))
            ((symbol-function 'maduin-cockpit--seat-status)
             (lambda (_seat) '(:status idle))))
    (should (equal (mapcar #'car (maduin-cockpit--rows))
                   '("alexander" "ramuh" "ifrit" "shiva")))))

(ert-deftest maduin-test-cockpit-surfaces-esper-seats ()
  "Reviewer and repairer seats are rows, grouped after the implementers."
  :tags '(maduin)
  (maduin-pipeline-config-bump)
  (let ((seats (maduin-cockpit--seats)))
    (should (equal (assoc "odin" seats) '("odin" . "reviewer")))
    (should (equal (assoc "phoenix" seats) '("phoenix" . "repairer"))))
  (cl-letf (((symbol-function 'maduin-cockpit--seat-status)
             (lambda (_seat) '(:status idle))))
    (should (equal (last (mapcar #'car (maduin-cockpit--rows)) 2)
                   '("odin" "phoenix")))))

(ert-deftest maduin-test-cockpit-esper-section-disabled-omits-seats ()
  "A disabled reviewer or repairer section contributes no cockpit rows."
  :tags '(maduin)
  (let ((maduin-config (copy-tree maduin-config)))
    (setcdr (assq 'enabled (cdr (assq 'reviewer maduin-config))) nil)
    (maduin-pipeline-config-bump)
    (should-not (assoc "odin" (maduin-cockpit--seats)))
    (should (assoc "phoenix" (maduin-cockpit--seats))))
  (maduin-pipeline-config-bump))

(ert-deftest maduin-test-cockpit-esper-seat-matches-role-entry ()
  "A repairer session shows on the esper's row though it names another seat."
  :tags '(maduin)
  (let ((maduin-dispatch--active
         (list (list :seat "ifrit" :role 'repairer :status 'repairing
                     :task "md-1" :model "m" :backend 'opencode))))
    (cl-letf (((symbol-function 'maduin-cockpit--seats)
               (lambda () '(("phoenix" . "repairer") ("odin" . "reviewer")))))
      (let ((phoenix (maduin-cockpit--seat-status "phoenix"))
            (odin (maduin-cockpit--seat-status "odin")))
        (should (eq (plist-get phoenix :status) 'repairing))
        (should (equal (plist-get phoenix :task-id) "md-1"))
        ;; A repairer session must not light up the reviewer's row.
        (should-not (plist-get odin :task-id))))))


;;; bd async substrate

(require 'maduin-bd-async)

(defun maduin-test--bd-async-wait ()
  "Wait for all async bd calls to complete, failing after two seconds."
  (let ((deadline (+ (float-time) 2.0)))
    (while (and (> (hash-table-count maduin-bd-async--inflight) 0)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (= (hash-table-count maduin-bd-async--inflight) 0))))

(ert-deftest maduin-test-bd-async-callback-fires ()
  :tags '(maduin)
  (let ((echo (executable-find "echo"))
        (seen nil))
    (skip-unless echo)
    (unwind-protect
        (let ((maduin-bd-async--program echo))
          (should (fboundp 'maduin-bd-async-json))
          (should (stringp
                   (maduin-bd-async-call
                    '("payload")
                    (lambda (exit-code stdout)
                      (setq seen (list exit-code stdout))))))
          (maduin-test--bd-async-wait)
          (should (equal seen '(0 "payload\n"))))
      (maduin-bd-async-cancel-all))))

(ert-deftest maduin-test-bd-async-single-flight ()
  :tags '(maduin)
  (let ((sh (executable-find "sh"))
        (spawned 0)
        (callbacks 0))
    (skip-unless sh)
    (unwind-protect
        (let ((maduin-bd-async--program sh)
              (original-make-process (symbol-function 'make-process)))
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest process-args)
                       (setq spawned (1+ spawned))
                       (apply original-make-process process-args))))
            (let ((args '("-c" "sleep 0.1; printf shared")))
              (maduin-bd-async-call args
                                    (lambda (exit-code stdout)
                                      (should (= exit-code 0))
                                      (should (string= stdout "shared"))
                                      (setq callbacks (1+ callbacks))))
              (maduin-bd-async-call args
                                    (lambda (exit-code stdout)
                                      (should (= exit-code 0))
                                      (should (string= stdout "shared"))
                                      (setq callbacks (1+ callbacks))))))
          (maduin-test--bd-async-wait)
          (should (= spawned 1))
          (should (= callbacks 2)))
      (maduin-bd-async-cancel-all))))

(ert-deftest maduin-test-bd-async-distinct-keys ()
  :tags '(maduin)
  (let ((echo (executable-find "echo"))
        (spawned 0)
        (seen nil))
    (skip-unless echo)
    (unwind-protect
        (let ((maduin-bd-async--program echo)
              (original-make-process (symbol-function 'make-process)))
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest process-args)
                       (setq spawned (1+ spawned))
                       (apply original-make-process process-args))))
            (maduin-bd-async-call '("one")
                                  (lambda (_exit-code stdout) (push stdout seen)))
            (maduin-bd-async-call '("two")
                                  (lambda (_exit-code stdout) (push stdout seen))))
          (maduin-test--bd-async-wait)
          (should (= spawned 2))
          (should (equal (sort seen #'string<) '("one\n" "two\n"))))
      (maduin-bd-async-cancel-all))))

(ert-deftest maduin-test-bd-async-nonzero-exit ()
  :tags '(maduin)
  (let ((sh (executable-find "sh"))
        (seen nil))
    (skip-unless sh)
    (unwind-protect
        (let ((maduin-bd-async--program sh))
          (maduin-bd-async-call
           '("-c" "exit 3")
           (lambda (exit-code stdout) (setq seen (list exit-code stdout))))
          (maduin-test--bd-async-wait)
          (should (= (car seen) 3))
          (should (string= (cadr seen) "")))
      (maduin-bd-async-cancel-all))))

(ert-deftest maduin-test-bd-async-callback-error-isolated ()
  :tags '(maduin)
  (let ((sh (executable-find "sh"))
        (second-ran nil))
    (skip-unless sh)
    (unwind-protect
        (let ((maduin-bd-async--program sh)
              (args '("-c" "sleep 0.1; printf done")))
          (maduin-bd-async-call args
                                (lambda (&rest _) (error "expected test callback error")))
          (maduin-bd-async-call args
                                (lambda (exit-code stdout)
                                  (setq second-ran (and (= exit-code 0)
                                                        (string= stdout "done")))))
          (maduin-test--bd-async-wait)
          (should second-ran))
      (maduin-bd-async-cancel-all))))

(ert-deftest maduin-test-bd-async-missing-program ()
  :tags '(maduin)
  (unwind-protect
      (let ((maduin-bd-async--program "maduin-no-such-bd-program-xyz"))
        (should-not (maduin-bd-async-call '("ready") (lambda (&rest _))))
        (should (= (hash-table-count maduin-bd-async--inflight) 0)))
    (maduin-bd-async-cancel-all)))


;;; 14. cockpit-render-scheduler

(ert-deftest maduin-test-cockpit-schedule-coalesces-burst ()
  :tags '(maduin)
  (let* ((buf (generate-new-buffer " *maduin-cockpit-schedule-burst*"))
         (maduin-cockpit-buffer-name (buffer-name buf))
        (clock 0.0) (renders 0) (scheduled nil)
        (maduin-cockpit--pending-render nil)
        (maduin-cockpit--last-render nil)
        (maduin-cockpit--now-fn (lambda () clock)))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (buffer &optional _all) (and (eq buffer buf) (selected-window))))
                  ((symbol-function 'timerp) (lambda (timer) (eq timer 'render-timer)))
                  ((symbol-function 'run-at-time)
                   (lambda (delay _repeat function &rest args)
                     (push (list delay function args) scheduled) 'render-timer))
                  ((symbol-function 'maduin-pipeline-status-refresh) (lambda (&optional _callback)))
                  ((symbol-function 'maduin-cockpit-refresh)
                   (lambda () (cl-incf renders)
                     (setq maduin-cockpit--last-render (funcall maduin-cockpit--now-fn)))))
          (dotimes (_ 50) (maduin-cockpit--schedule-refresh))
          (should (= renders 0))
          (should (= (length scheduled) 1))
          (apply (nth 1 (car scheduled)) (nth 2 (car scheduled)))
          (dotimes (_ 50) (maduin-cockpit--schedule-refresh))
          (should (= renders 1))
          (should (= (length scheduled) 2))
          (setq clock maduin-cockpit-min-render-interval)
          (apply (nth 1 (car scheduled)) (nth 2 (car scheduled)))
          (should (= renders 2)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest maduin-test-cockpit-schedule-not-starved ()
  :tags '(maduin)
  (let* ((buf (generate-new-buffer " *maduin-cockpit-schedule-stream*"))
         (maduin-cockpit-buffer-name (buffer-name buf))
        (clock 0.0) (renders 0) (scheduled nil)
        (maduin-cockpit--pending-render nil)
        (maduin-cockpit--last-render nil)
        (maduin-cockpit--now-fn (lambda () clock)))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (buffer &optional _all) (and (eq buffer buf) (selected-window))))
                  ((symbol-function 'timerp) (lambda (timer) (eq timer 'render-timer)))
                  ((symbol-function 'run-at-time)
                   (lambda (delay _repeat function &rest args)
                     (push (list delay function args) scheduled) 'render-timer))
                  ((symbol-function 'maduin-pipeline-status-refresh) (lambda (&optional _callback)))
                  ((symbol-function 'maduin-cockpit-refresh)
                   (lambda () (cl-incf renders)
                     (setq maduin-cockpit--last-render (funcall maduin-cockpit--now-fn)))))
          (maduin-cockpit--schedule-refresh)
          (apply (nth 1 (car scheduled)) (nth 2 (car scheduled)))
          (dotimes (interval 3)
            (setq clock (+ (* interval maduin-cockpit-min-render-interval) 0.01))
            (dotimes (_ 50) (maduin-cockpit--schedule-refresh))
            (setq clock (* (1+ interval) maduin-cockpit-min-render-interval))
            (apply (nth 1 (car scheduled)) (nth 2 (car scheduled))))
          (should (>= renders 4)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest maduin-test-cockpit-schedule-hidden-buffer-noop ()
  :tags '(maduin)
  (let* ((buf (generate-new-buffer " *maduin-cockpit-schedule-hidden*"))
         (maduin-cockpit-buffer-name (buffer-name buf))
        (renders 0) (maduin-cockpit--pending-render nil))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
                  ((symbol-function 'run-at-time) (lambda (&rest _) (error "unexpected timer")))
                  ((symbol-function 'maduin-cockpit-refresh) (lambda () (cl-incf renders))))
          (maduin-cockpit--schedule-refresh)
          (should (= renders 0))
          (should-not maduin-cockpit--pending-render))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest maduin-test-cockpit-schedule-timer-cleared-on-kill ()
  :tags '(maduin)
  (let ((buf (generate-new-buffer " *maduin-cockpit-schedule-kill*"))
        (cancelled 0) (maduin-cockpit-buffer-name " *maduin-cockpit-schedule-kill*")
        (maduin-cockpit--timer nil) (maduin-cockpit--pending-render nil))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (buffer &optional _all) (and (eq buffer buf) (selected-window))))
                  ((symbol-function 'timerp) (lambda (timer) (eq timer 'render-timer)))
                  ((symbol-function 'run-at-time) (lambda (&rest _) 'render-timer))
                  ((symbol-function 'cancel-timer) (lambda (&rest _) (cl-incf cancelled))))
          (with-current-buffer buf
            (add-hook 'kill-buffer-hook #'maduin-cockpit--stop-timer nil t))
          (maduin-cockpit--schedule-refresh)
          (kill-buffer buf)
          (should-not maduin-cockpit--pending-render)
          (should (= cancelled 1)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest maduin-test-dispatch-notify-skips-unchanged-status ()
  :tags '(maduin)
  (let ((maduin-dispatch--active
         (list (list :handle "h1" :status 'working :phase nil)))
        (notifies 0))
    (cl-letf (((symbol-function 'maduin-dispatch--notify)
               (lambda (&optional _reason) (cl-incf notifies))))
      (maduin-dispatch--set-status "h1" 'running)
      (maduin-dispatch--set-status "h1" 'running)
      (should (= notifies 1))
      (maduin-dispatch--on-event "h1" 'tool)
      (maduin-dispatch--on-event "h1" 'tool)
      (should (= notifies 2)))))


;;; Dispatch async run-loop

(ert-deftest maduin-test-dispatch-run-loop-async ()
  :tags '(maduin)
  (let* ((implemented nil) (decomposed nil) (children nil)
        (maduin-dispatch--active nil)
        (maduin-dispatch--draining nil)
        (maduin-dispatch--tick-in-flight nil)
        (maduin-dispatch--drift-fix-async-fn
         (lambda (callback) (funcall callback nil t) (quote drift-fix)))
        (maduin-dispatch--in-progress-async-fn
         (lambda (callback) (funcall callback '("orphan") t) 'in-progress))
        (maduin-dispatch--ready-async-fn
         (lambda (callback) (funcall callback '("ready") t) 'ready))
        (maduin-dispatch--open-epics-async-fn
         (lambda (callback) (funcall callback '("epic-full" "epic-empty") t) 'epics))
        (maduin-dispatch--epic-children-async-fn
         (lambda (epic callback) (push (cons epic callback) children) epic))
        (maduin-dispatch--epic-decompose-fn
         (lambda (epic) (push epic decomposed))))
    (cl-letf (((symbol-function 'maduin-dispatch-implement)
               (lambda (task) (push task implemented) task)))
      (maduin-dispatch-run-loop)
      ;; All children start before either is answered: concurrent fan-out.
      (should (equal implemented '("ready" "orphan")))
      (should (= (length children) 2))
      (funcall (cdr (assoc "epic-full" children)) '("child") t)
      (should-not decomposed)
      (funcall (cdr (assoc "epic-empty" children)) nil t)
      (should (equal decomposed '("epic-empty")))
      (should-not maduin-dispatch--tick-in-flight))))

(ert-deftest maduin-test-dispatch-run-loop-no-sync-query ()
  :tags '(maduin)
  (let ((maduin-dispatch--active nil)
        (maduin-dispatch--draining nil)
        (maduin-dispatch--tick-in-flight nil)
        (maduin-dispatch--drift-fix-async-fn
         (lambda (callback) (funcall callback nil t) (quote drift-fix)))
        (maduin-dispatch--in-progress-async-fn
         (lambda (callback) (funcall callback nil t) 'in-progress))
        (maduin-dispatch--ready-async-fn
         (lambda (callback) (funcall callback nil t) 'ready))
        (maduin-dispatch--open-epics-async-fn
         (lambda (callback) (funcall callback nil t) 'epics)))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (ert-fail "synchronous bd call")))
              ((symbol-function 'call-process-shell-command)
               (lambda (&rest _) (ert-fail "synchronous shell call"))))
      (maduin-dispatch-run-loop)
      (should-not maduin-dispatch--tick-in-flight))))

(ert-deftest maduin-test-dispatch-run-loop-reentrancy ()
  :tags '(maduin)
  (let* ((queries 0) (implemented nil) callback
        (maduin-dispatch--active nil)
        (maduin-dispatch--draining nil)
        (maduin-dispatch--tick-in-flight nil)
        (maduin-dispatch--drift-fix-async-fn
         (lambda (callback) (funcall callback nil t) (quote drift-fix)))
        (maduin-dispatch--in-progress-async-fn
         (lambda (continuation) (setq queries (1+ queries) callback continuation) 'in-progress))
        (maduin-dispatch--ready-async-fn
         (lambda (continuation) (funcall continuation '("ready") t) 'ready))
        (maduin-dispatch--open-epics-async-fn
         (lambda (continuation) (funcall continuation nil t) 'epics)))
    (cl-letf (((symbol-function 'maduin-dispatch-implement)
               (lambda (task) (push task implemented) task)))
      (maduin-dispatch-run-loop)
      (maduin-dispatch-run-loop)
      (should (= queries 1))
      (funcall callback nil t)
      (should (equal implemented '("ready")))
      (should-not maduin-dispatch--tick-in-flight))))

(ert-deftest maduin-test-dispatch-run-loop-drain-midchain ()
  :tags '(maduin)
  (let ((implemented nil)
        (maduin-dispatch--active nil)
        (maduin-dispatch--draining nil)
        (maduin-dispatch--tick-in-flight nil)
        (maduin-dispatch--drift-fix-async-fn
         (lambda (callback) (funcall callback nil t) (quote drift-fix)))
        (maduin-dispatch--in-progress-async-fn
         (lambda (callback) (funcall callback nil t) 'in-progress))
        (maduin-dispatch--ready-async-fn
         (lambda (callback)
           (setq maduin-dispatch--draining t)
           (funcall callback '("ready") t) 'ready))
        (maduin-dispatch--open-epics-async-fn
         (lambda (callback) (funcall callback '("epic") t) 'epics)))
    (cl-letf (((symbol-function 'maduin-dispatch-implement)
               (lambda (task) (push task implemented) task)))
      (maduin-dispatch-run-loop)
      (should-not implemented)
      (should-not maduin-dispatch--tick-in-flight))))

(ert-deftest maduin-test-dispatch-run-loop-query-failure ()
  :tags '(maduin)
  (let* ((queries 0)
        (maduin-dispatch--active nil)
        (maduin-dispatch--draining nil)
        (maduin-dispatch--tick-in-flight nil)
        (maduin-dispatch--drift-fix-async-fn
         (lambda (callback) (funcall callback nil t) (quote drift-fix)))
        (maduin-dispatch--in-progress-async-fn
         (lambda (callback)
           (setq queries (1+ queries))
           (funcall callback nil (> queries 1))
           'in-progress))
        (maduin-dispatch--ready-async-fn
         (lambda (callback) (funcall callback nil t) 'ready))
        (maduin-dispatch--open-epics-async-fn
         (lambda (callback) (funcall callback nil t) 'epics)))
    (maduin-dispatch-run-loop)
    (should-not maduin-dispatch--tick-in-flight)
    (maduin-dispatch-run-loop)
    (should (= queries 2))
    (should-not maduin-dispatch--tick-in-flight)))


(ert-deftest maduin-test-dispatch-stop-cancels-async-tick ()
  :tags '(maduin)
  (let ((timer (run-at-time 60 nil #'ignore))
        (cancelled 0)
        (maduin-dispatch--timer nil)
        (maduin-dispatch--active nil)
        (maduin-dispatch--draining nil)
        (maduin-dispatch--tick-in-flight t))
    (unwind-protect
        (cl-letf (((symbol-function 'maduin-bd-async-cancel-all)
                   (lambda () (setq cancelled (1+ cancelled)))))
          (setq maduin-dispatch--timer timer)
          (maduin-dispatch-stop)
          (should (= cancelled 1))
          (should-not maduin-dispatch--timer)
          (should-not maduin-dispatch--tick-in-flight))
      (when (timerp timer) (cancel-timer timer)))))


(ert-deftest maduin-test-dispatch-run-loop-coalesces-notify ()
  :tags '(maduin)
  (let* ((count 0)
         (maduin-cockpit-refresh-hook (list (lambda () (setq count (1+ count)))))
         (maduin-dispatch--active nil)
         (maduin-dispatch--draining nil)
         (maduin-dispatch--tick-in-flight nil)
         (maduin-dispatch--tick-notify-pending nil)
         (maduin-dispatch--drift-fix-async-fn
          (lambda (callback) (funcall callback nil t) (quote drift-fix)))
         (maduin-dispatch--in-progress-async-fn
          (lambda (callback) (funcall callback '("orphan") t) 'in-progress))
         (maduin-dispatch--ready-async-fn
          (lambda (callback) (funcall callback '("ready") t) 'ready))
         (maduin-dispatch--open-epics-async-fn
          (lambda (callback) (funcall callback nil t) 'epics)))
    (cl-letf (((symbol-function 'maduin-dispatch-implement)
               (lambda (_task) (maduin-dispatch--notify) t)))
      (maduin-dispatch-run-loop)
      (should (= count 1)))))


(defun maduin-test--dispatch-tier-spawn (backend difficulty)
  "Spawn a tiered implementer with mocked dispatch seams for ERT assertions."
  (let* ((maduin-config (copy-tree maduin-config))
         (maduin-dispatch--active nil)
         (received nil)
         (maduin-dispatch--difficulty-fn (lambda (_task) difficulty))
         (maduin-dispatch--claim-fn (lambda (_task) t))
         (maduin-dispatch--show-fn (lambda (_task) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_seat) "/work"))
         (maduin-dispatch--session-run-fn
          (lambda (workdir model agent plan run-backend &optional effort)
            (setq received (list workdir model agent plan run-backend effort))
            "tier-session")))
    (setcdr (assq 'backend (cdr (assq 'crew maduin-config))) backend)
    (maduin-dispatch-implement "tier-task")
    (list :entry (car maduin-dispatch--active) :received received)))

(ert-deftest maduin-test-dispatch-spawn-low-uses-luna ()
  :tags '(maduin)
  (let* ((result (maduin-test--dispatch-tier-spawn 'kiro 'low))
         (entry (plist-get result :entry)))
    (should (equal (plist-get entry :model) "gpt-5.6-luna"))
    (should (equal (plist-get entry :effort) "medium"))
    (should (eq (plist-get entry :difficulty) 'low))
    (should (equal (nth 5 (plist-get result :received)) "medium"))))

(ert-deftest maduin-test-dispatch-spawn-high-uses-terra ()
  :tags '(maduin)
  (let* ((result (maduin-test--dispatch-tier-spawn 'kiro 'high))
         (entry (plist-get result :entry)))
    (should (equal (plist-get entry :model) "gpt-5.6-terra"))
    (should (equal (plist-get entry :effort) "high"))
    (should (eq (plist-get entry :difficulty) 'high))
    (should (equal (nth 5 (plist-get result :received)) "high"))))

(ert-deftest maduin-test-dispatch-spawn-opencode-ignores-difficulty ()
  :tags '(maduin)
  (dolist (difficulty '(low high))
    (let* ((result (maduin-test--dispatch-tier-spawn 'opencode difficulty))
           (entry (plist-get result :entry)))
      (should (equal (plist-get entry :model) "opencode/deepseek-v4-flash-free"))
      (should-not (plist-get entry :effort))
      (should (eq (plist-get entry :difficulty) difficulty))
      (should-not (nth 5 (plist-get result :received))))))

(ert-deftest maduin-test-dispatch-spawn-difficulty-error-defaults ()
  :tags '(maduin)
  (let* ((maduin-config (copy-tree maduin-config))
         (maduin-dispatch--active nil)
         (released nil)
         (received nil)
         (maduin-dispatch--difficulty-fn (lambda (_task) (error "bd unavailable")))
         (maduin-dispatch--claim-fn (lambda (_task) t))
         (maduin-dispatch--release-fn (lambda (task) (setq released task) t))
         (maduin-dispatch--show-fn (lambda (_task) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_seat) "/work"))
         (maduin-dispatch--session-run-fn
          (lambda (_workdir model _agent _plan _backend &optional effort)
            (setq received (list model effort))
            "tier-session")))
    (setcdr (assq 'backend (cdr (assq 'crew maduin-config))) 'kiro)
    (should (equal (maduin-dispatch-implement "tier-task") "tier-session"))
    (let ((entry (car maduin-dispatch--active)))
      (should (equal (plist-get entry :model) "gpt-5.6-terra"))
      (should-not (plist-get entry :difficulty))
      (should-not (plist-get entry :effort)))
    (should (equal received '("gpt-5.6-terra" nil)))
    (should-not released)))

(ert-deftest maduin-test-dispatch-spawn-explicit-model-skips-resolution ()
  :tags '(maduin)
  (let* ((calls 0)
         (maduin-dispatch--active nil)
         (maduin-dispatch--difficulty-fn (lambda (_task) (cl-incf calls) 'low))
         (maduin-dispatch--show-fn (lambda (_task) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_seat) "/work"))
         (maduin-dispatch--session-run-fn
          (lambda (_workdir model _agent _plan _backend &optional effort)
            (should (equal model "explicit-model"))
            (should-not effort)
            "tier-session")))
    (should (equal (maduin-dispatch--spawn-session
                    "tier-task" 'implementer "ifrit" "explicit-model" nil nil 'kiro)
                   "tier-session"))
    (should (= calls 0))))

(ert-deftest maduin-test-dispatch-fallback-retains-difficulty-and-effort ()
  :tags '(maduin)
  (let* ((maduin-config (copy-tree maduin-config))
         (maduin-dispatch--active nil)
         (runs nil)
         (maduin-dispatch--difficulty-fn (lambda (_task) 'low))
         (maduin-dispatch--claim-fn (lambda (_task) t))
         (maduin-dispatch--show-fn (lambda (_task) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_seat) "/work"))
         (maduin-dispatch--comment-fn (lambda (_task _text) t))
         (maduin-dispatch--session-delete-fn (lambda (_backend _sid) t))
         (maduin-dispatch--session-run-fn
          (lambda (_workdir model _agent _plan backend &optional effort)
            (push (list model backend effort) runs)
            (format "tier-%d" (length runs)))))
    (setcdr (assq 'backend (cdr (assq 'crew maduin-config))) 'kiro)
    (maduin-dispatch-implement "tier-task")
    (maduin-dispatch--on-complete "tier-1" 'limited)
    (let ((entry (car maduin-dispatch--active)))
      (should (equal (plist-get entry :model) "gpt-5.6-terra"))
      (should (eq (plist-get entry :backend) 'kiro))
      (should (eq (plist-get entry :difficulty) 'low))
      (should (equal (plist-get entry :effort) "medium")))
    (should (equal (nreverse runs)
                   '(("gpt-5.6-luna" kiro "medium")
                     ("gpt-5.6-terra" kiro "medium"))))))

(ert-deftest maduin-test-dispatch-spawn-designer-model-unchanged ()
  :tags '(maduin)
  (let* ((maduin-config (copy-tree maduin-config))
         (maduin-dispatch--active nil)
         (calls 0)
         (models nil)
         (maduin-dispatch--difficulty-fn
          (lambda (_task) (cl-incf calls) (error "must not resolve")))
         (maduin-dispatch--show-fn (lambda (_task) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_seat) "/work"))
         (maduin-dispatch--session-run-fn
          (lambda (_workdir model _agent _plan _backend &optional effort)
            (push (list model effort) models)
            (format "tier-%d" (length models)))))
    (setcdr (assq 'backend (cdr (assq 'crew maduin-config))) 'kiro)
    (maduin-dispatch--spawn-session "designer-task" 'designer "ramuh" nil nil nil 'kiro)
    (maduin-dispatch--spawn-session "repair-task" 'repairer "phoenix" nil nil nil 'kiro)
    (should (= calls 0))
    (should (equal (nreverse models)
                   '(("gpt-5.6-terra" nil) ("gpt-5.6-terra" nil))))))

;;; Regression: cockpit + dispatch + land bug fixes

(ert-deftest maduin-test-dispatch-set-status-preserves-other-entries ()
  :tags '(maduin)
  ;; A status change on one handle must leave every other active entry
  ;; intact.  A dropped else branch used to replace them with nil, which
  ;; broke completion routing, drain detection, and the cockpit idle cue.
  (let ((maduin-dispatch--active
         (list (list :handle "s1" :seat "ifrit" :role 'implementer
                     :task "t1" :status 'working)
               (list :handle "s2" :seat "shiva" :role 'implementer
                     :task "t2" :status 'working)
               (list :handle "s3" :seat "titan" :role 'implementer
                     :task "t3" :status 'working))))
    (cl-letf (((symbol-function 'maduin-dispatch--notify) #'ignore))
      (should (maduin-dispatch--set-status "s3" 'failed)))
    (should (= (length maduin-dispatch--active) 3))
    (should-not (memq nil maduin-dispatch--active))
    (should (equal (mapcar (lambda (e) (plist-get e :handle))
                          maduin-dispatch--active)
                   '("s1" "s2" "s3")))
    (should (eq (plist-get (nth 2 maduin-dispatch--active) :status) 'failed))
    (should (eq (plist-get (nth 0 maduin-dispatch--active) :status) 'working))))

(ert-deftest maduin-test-dispatch-on-complete-survives-nil-entries ()
  :tags '(maduin)
  ;; Defensive: a nil entry in the registry must not signal
  ;; (wrong-type-argument stringp nil) from the handle lookup.
  (let* ((completed nil)
         (maduin-dispatch--active
          (list nil (list :handle "s2" :seat "shiva" :role 'implementer
                          :task "t2" :backend 'opencode :status 'working)))
         (maduin-dispatch--session-delete-fn (lambda (_backend _sid) t))
         (maduin-dispatch--diff-fn (lambda (_backend _sid) nil))
         (maduin-dispatch--land-fn (lambda (_seat &optional _stamp) nil))
         (maduin-dispatch--comment-fn (lambda (_id _text) t))
         (maduin-dispatch--release-fn (lambda (task) (setq completed task) t)))
    (cl-letf (((symbol-function 'maduin-dispatch--notify) #'ignore))
      (maduin-dispatch--on-complete "s2" 'completed))
    (should (equal completed "t2"))))

(ert-deftest maduin-test-cockpit-refresh-never-renders-foreign-buffer ()
  :tags '(maduin)
  ;; `tabulated-list-print' erases its buffer.  A stray refresh (e.g. from
  ;; `maduin-status' in an ordinary buffer) must leave that buffer untouched.
  (let ((buf (generate-new-buffer " *maduin-cockpit-foreign*"))
        (maduin-cockpit-buffer-name " *maduin-cockpit-absent*"))
    (unwind-protect
        (with-current-buffer buf
          (insert "user content")
          (maduin-cockpit-refresh)
          (should (equal (buffer-string) "user content"))
          (should (null tabulated-list-format)))
      (kill-buffer buf))))

(ert-deftest maduin-test-cockpit-window-change-rearms-timer ()
  :tags '(maduin)
  ;; The auto-refresh timer self-cancels once the cockpit is hidden.  Any
  ;; route that re-displays the buffer must arm it again, or derived columns
  ;; (uptime) freeze at the value last painted.
  (let* ((buf (generate-new-buffer " *maduin-cockpit-rearm*"))
         (maduin-cockpit-buffer-name (buffer-name buf))
         (maduin-cockpit--timer nil)
         (maduin-cockpit--pending-render nil)
         (started nil))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (buffer &optional _all)
                     (and (eq (get-buffer buffer) buf) (selected-window))))
                  ((symbol-function 'run-at-time)
                   (lambda (_delay repeat function &rest _args)
                     (when repeat (setq started function))
                     'timer))
                  ((symbol-function 'timerp) (lambda (timer) (eq timer 'timer))))
          (maduin-cockpit--on-window-change)
          (should (eq started #'maduin-cockpit--auto-refresh))
          (should maduin-cockpit--timer))
      (kill-buffer buf))))

(ert-deftest maduin-test-land-branch-diverged-main-rebases-again ()
  :tags '(maduin)
  ;; A concurrent seat landing between our rebase and our fast-forward moves
  ;; main forward: ff-only is refused with "Diverging branches" although
  ;; nothing conflicts.  Land must rebase once more and retry the ff.
  (let* ((merges 0)
         (rebases 0)
         (maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
         (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
         (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
         (maduin-pipeline--git-fn (lambda (_dir &rest _args) 0))
         (maduin-pipeline--git-output-fn
          (lambda (_dir &rest args)
            (cond
             ((member "commit" args) (cons 0 ""))
             ((member "rev-parse" args) (cons 0 "abc123\n"))
             ((member "rebase" args) (cl-incf rebases) (cons 0 ""))
             ((member "merge" args)
              (cl-incf merges)
              (if (= merges 1)
                  (cons 128 "hint: Diverging branches can't be fast-forwarded\nfatal: Not possible to fast-forward, aborting.\n")
                (cons 0 "")))))))
    (should (eq (maduin-pipeline-land-branch "test-seat") t))
    (should (= rebases 2))
    (should (= merges 2))))

(ert-deftest maduin-test-land-branch-diverged-then-conflict ()
  :tags '(maduin)
  ;; The re-rebase can hit a real content conflict; that must surface as
  ;; `conflict' so a repairer is dispatched instead of silently releasing.
  (let* ((rebases 0)
         (maduin-pipeline--worktree-path-fn (lambda (_s) maduin-test--dir))
         (maduin-pipeline--branch-fn (lambda (_s) "seat-branch-xyz"))
         (maduin-pipeline--main-root-fn (lambda () maduin-test--dir))
         (maduin-pipeline--git-fn (lambda (_dir &rest _args) 0))
         (maduin-pipeline--git-output-fn
          (lambda (_dir &rest args)
            (cond
             ((member "commit" args) (cons 0 ""))
             ((member "rev-parse" args) (cons 0 "abc123\n"))
             ((member "rebase" args)
              (cl-incf rebases)
              (if (= rebases 1)
                  (cons 0 "")
                (cons 1 "CONFLICT (content): Merge conflict in Makefile\n")))
             ((member "merge" args)
              (cons 128 "fatal: Not possible to fast-forward, aborting.\n"))))))
    (should (eq (maduin-pipeline-land-branch "test-seat") 'conflict))
    (should (= rebases 2))))

;;; Pre-dispatch worktree sync

(defmacro maduin-test--with-sync-git (state &rest body)
  "Run BODY with workspace git seams driven by STATE.
STATE is a plist read by the stubs: :ancestors is an alist of
\((ANCESTOR . DESCENDANT) . BOOLEAN), :status is porcelain output, :rebase is
a (STATUS . OUTPUT) cons, :reset is an exit status.  Issued commands
accumulate in the dynamically bound `calls' list."
  (declare (indent 1) (debug t))
  `(let* ((state ,state)
          (calls nil)
          (maduin-workspace--main-root-fn (lambda () maduin-test--dir))
          (maduin-workspace--git-fn
           (lambda (_dir &rest args)
             (push args calls)
             (cond
              ((member "merge-base" args)
               (let ((pair (cons (nth 2 args) (nth 3 args))))
                 (if (cdr (assoc pair (plist-get state :ancestors))) 0 1)))
              ((member "reset" args) (or (plist-get state :reset) 0))
              (t 0))))
          (maduin-workspace--git-output-fn
           (lambda (_dir &rest args)
             (push args calls)
             (cond
              ((member "status" args)
               (cons 0 (or (plist-get state :status) "")))
              ((member "rebase" args)
               (or (plist-get state :rebase) (cons 0 "")))
              (t (cons 0 ""))))))
     (cl-letf (((symbol-function 'maduin-workspace-path)
                (lambda (_seat) maduin-test--dir)))
       ,@body)))

(ert-deftest maduin-test-workspace-sync-already-current ()
  :tags '(maduin)
  (maduin-test--with-sync-git '(:ancestors ((("main" . "ifrit") . t)))
    (should (eq (maduin-workspace-sync "ifrit") 'synced))
    ;; No tree-mutating command may run when the branch already holds main.
    (should-not (cl-some (lambda (args)
                           (or (member "reset" args) (member "rebase" args)))
                         calls))))

(ert-deftest maduin-test-workspace-sync-resets-landed-branch ()
  :tags '(maduin)
  ;; Branch fully landed (ancestor of main) and clean → discard the stale
  ;; baseline: the next task starts from main, not from 50 commits back.
  (maduin-test--with-sync-git '(:ancestors (((("main" . "ifrit")) . nil)
                                            (("ifrit" . "main") . t)))
    (should (eq (maduin-workspace-sync "ifrit") 'synced))
    (should (cl-some (lambda (args) (equal args '("reset" "--hard" "main")))
                     calls))
    (should-not (cl-some (lambda (args) (member "rebase" args)) calls))))

(ert-deftest maduin-test-workspace-sync-rebases-unlanded-work ()
  :tags '(maduin)
  ;; Unlanded commits must be rebased, never reset away.
  (maduin-test--with-sync-git '(:ancestors nil)
    (should (eq (maduin-workspace-sync "ifrit") 'synced))
    (should (cl-some (lambda (args) (equal args '("rebase" "main" "ifrit")))
                     calls))
    (should-not (cl-some (lambda (args) (member "reset" args)) calls))))

(ert-deftest maduin-test-workspace-sync-conflict-aborts ()
  :tags '(maduin)
  (maduin-test--with-sync-git
      '(:ancestors nil
        :rebase (1 . "CONFLICT (content): Merge conflict in Makefile\n"))
    (should (eq (maduin-workspace-sync "ifrit") 'conflict))
    (should (cl-some (lambda (args) (equal args '("rebase" "--abort"))) calls))))

(ert-deftest maduin-test-workspace-sync-dirty-tree-untouched ()
  :tags '(maduin)
  ;; Uncommitted work is never discarded or rebased under the agent's feet.
  (maduin-test--with-sync-git '(:ancestors nil :status " M harness/foo.el\n")
    (should (eq (maduin-workspace-sync "ifrit") 'dirty))
    (should-not (cl-some (lambda (args)
                           (or (member "reset" args) (member "rebase" args)))
                         calls))))

(ert-deftest maduin-test-dispatch-syncs-seat-before-claim ()
  :tags '(maduin)
  (let* ((order nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--sync-fn (lambda (seat) (push (cons 'sync seat) order) 'synced))
         (maduin-dispatch--workdir-fn (lambda (_seat) "/work"))
         (maduin-dispatch--claim-fn (lambda (task) (push (cons 'claim task) order) t))
         (maduin-dispatch--show-fn (lambda (_task) (list :title "T" :desc "D")))
         (maduin-dispatch--difficulty-fn (lambda (_task) nil))
         (maduin-dispatch--session-run-fn
          (lambda (&rest _args) "sync-session")))
    (should (equal (maduin-dispatch-implement "t1") "sync-session"))
    ;; Sync must precede the claim: a seat that cannot take work must not
    ;; leave a task claimed and stranded.
    (should (equal (nreverse order) '((sync . "ifrit") (claim . "t1"))))))

(ert-deftest maduin-test-dispatch-refuses-conflicting-seat ()
  :tags '(maduin)
  (let* ((claimed nil)
         (comments nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--sync-fn (lambda (_seat) 'conflict))
         (maduin-dispatch--workdir-fn (lambda (_seat) "/work"))
         (maduin-dispatch--claim-fn (lambda (_task) (setq claimed t) t))
         (maduin-dispatch--comment-fn
          (lambda (_id text) (push text comments) t))
         (maduin-dispatch--session-run-fn
          (lambda (&rest _args) (error "must not spawn"))))
    (should-not (maduin-dispatch-implement "t1"))
    (should-not claimed)
    (should (= (length comments) 1))
    (should (string-match-p "conflicting with main" (car comments)))))

(ert-deftest maduin-test-dispatch-repairer-skips-sync ()
  :tags '(maduin)
  ;; The repairer exists to resolve a diverged seat; syncing it first would
  ;; rebase or discard the very work it was dispatched to fix.
  (let* ((synced nil)
         (maduin-dispatch--active nil)
         (maduin-dispatch--sync-fn (lambda (_seat) (setq synced t) 'synced))
         (maduin-dispatch--workdir-fn (lambda (_seat) "/work"))
         (maduin-dispatch--claim-fn (lambda (_task) t))
         (maduin-dispatch--session-run-fn (lambda (&rest _args) "repair-session")))
    (cl-letf (((symbol-function 'maduin-dispatch--notify) #'ignore))
      (should (equal (maduin-dispatch-repair "shiva" "t1") "repair-session")))
    (should-not synced)))

(ert-deftest maduin-test-dispatch-sync-seam-default ()
  :tags '(maduin)
  ;; The suite neutralises the seam at load time; the shipped default must
  ;; still be the real sync, or dispatch would silently stop syncing seats.
  (should (eq maduin-test--dispatch-sync-default #'maduin-workspace-sync)))

(ert-deftest maduin-test-repair-plan-rebases-not-merges ()
  :tags '(maduin)
  (let ((plan (maduin-dispatch--repair-plan "shiva" "t1")))
    (should (string-match-p "git rebase main" plan))
    (should (string-match-p "rebase --continue" plan))
    (should-not (string-match-p "git merge main" plan))))
