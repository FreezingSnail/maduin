;;; probe-recover.el --- debug full-loop run-loop failure  -*- lexical-binding: t; -*-
(ert-deftest probe-recover-full-loop ()
  :tags '(probe)
  (let* ((dir (maduin-test--temp-dir))
         (task "orphan-6ab4-probe")
         (maduin-dispatch--active nil)
         (maduin-dispatch--ready-fn (lambda () (list task)))
         (maduin-dispatch--in-progress-fn (lambda () nil))
         (maduin-dispatch--open-epics-fn (lambda () nil))
         (maduin-dispatch--session-run-fn (lambda (_w _m _a _p) "s-probe-1"))
         (maduin-dispatch--claim-fn (lambda (_t) t))
         (maduin-dispatch--show-fn (lambda (_t) (list :title "T" :desc "D")))
         (maduin-dispatch--workdir-fn (lambda (_s) dir)))
    (unwind-protect
        (progn
          (maduin-dispatch-run-loop)
          (message "probe: active=%S free-seats=%S cap=%d"
                   maduin-dispatch--active
                   (maduin-dispatch--free-seat 'implementer)
                   (maduin-dispatch--role-cap 'implementer))
          (should (= (length maduin-dispatch--active) 1)))
      (delete-directory dir t))))