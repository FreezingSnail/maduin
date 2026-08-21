;;; probe-cockpit-perf.el --- exploratory cockpit timing probe  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(ert-deftest probe-cockpit-perf-refresh-timing ()
  :tags '(probe)
  (let* ((seats (cl-loop for i below 50
                         collect (cons (format "seat-%02d" i) "implementer")))
         (active (cl-loop for (seat . _role) in seats
                          for i from 0
                          collect (list :handle (format "perf-%02d" i)
                                        :seat seat :role 'implementer
                                        :task (format "task-%02d" i)
                                        :model "flash" :backend 'opencode
                                        :started 0.0 :status 'working
                                        :phase "render probe")))
         (titles (make-hash-table :test #'equal))
         (buf (generate-new-buffer " *maduin-cockpit-perf-probe*"))
         (maduin-state--data nil)
         (maduin-dispatch--active active)
         (iterations 20)
         (render-count 0)
         samples)
    (unwind-protect
        (progn
          (dolist (entry active)
            (let ((task (plist-get entry :task)))
              (puthash task (cons (format "Synthetic task %s" task) 0.0) titles)))
          (maduin-state-put 'titles titles)
          (maduin-state-put 'pipeline
                             '(:queued 12 :active 50 :completed 100 :blocked 3
                               :fleet-free 0 :fleet-busy 50))
          (with-current-buffer buf
            (tabulated-list-mode)
            (let ((snapshot-start (float-time)))
              (maduin-pipeline-status)
              (let ((snapshot-seconds (- (float-time) snapshot-start))
                    (print (symbol-function 'maduin-cockpit--print-rows)))
                (cl-letf (((symbol-function 'maduin-cockpit--seats)
                           (lambda () seats))
                          ((symbol-function 'maduin-cockpit--print-rows)
                           (lambda (rows)
                             (cl-incf render-count)
                             (funcall print rows))))
                  (dotimes (_ iterations)
                    (let ((started (float-time)))
                      (maduin-cockpit-refresh)
                      (push (- (float-time) started) samples))))
                (let* ((mean (/ (apply #'+ samples) iterations))
                       (maximum (apply #'max samples)))
                  (message
                   "probe cockpit perf: seats=50 refreshes=%d snapshot=%.3fms mean=%.3fms max=%.3fms renders=%d"
                   iterations (* snapshot-seconds 1000.0) (* mean 1000.0)
                   (* maximum 1000.0) render-count)
                  (should (= render-count 1))
                  (should (<= render-count iterations))))))
      (when (buffer-live-p buf) (kill-buffer buf))))))

;;; probe-cockpit-perf.el ends here
