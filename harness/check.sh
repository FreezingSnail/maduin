#!/usr/bin/env bash
# check.sh — compile + ERT; successful subprocess logs remain quiet.
# Usage: ./check.sh [-c|-k|probe probes/foo.el]
# Exit: 0 green, 1 compile error, 2 test fail, 3 probe fail, 5 warnings.

set -uo pipefail

EMACS="${EMACS:-emacs}"
PKG="maduin"
TEST="${PKG}-test"
STRICT="${STRICT:-1}"
FILES=(
  "config.el"
  "maduin-logging.el"
  "maduin-config.el"
  "maduin-bd-bridge.el"
  "maduin-session.el"
  "maduin-backend.el"
  "maduin-kiro.el"
  "maduin-workspace.el"
  "maduin-terminal.el"
  "maduin-stamp.el"
  "maduin-pipeline.el"
  "maduin-review.el"
  "maduin-handoff.el"
  "maduin-dispatch.el"
  "maduin-cockpit-face.el"
  "maduin-cockpit-bar.el"
  "maduin-cockpit-config.el"
  "maduin-cockpit.el"
  "maduin-designer.el"
  "maduin-concierge.el"
  "maduin.el"
  "maduin-test.el"
)

cd "$(dirname "${BASH_SOURCE[0]}")"
warned=0

clean() { rm -f ./*.elc; }

compile() {
  echo "=== COMPILE ==="
  local out rc
  FILES_JOINED="$(IFS=:; printf '%s' "${FILES[*]}")"
  out="$(FILES_JOINED="$FILES_JOINED" "$EMACS" -Q --batch -L . --eval '
    (let ((files (split-string (or (getenv "FILES_JOINED") "") ":")))
      (dolist (f files)
        (unless (string-suffix-p "-test.el" f)
          (condition-case e
              (load (file-name-sans-extension f) nil t)
            (error (message "LOAD SKIP %s: %s" f (error-message-string e))))))
      (dolist (f files)
        (condition-case e
            (byte-compile-file f)
          (error (message "COMPILE ERROR %s: %s" f (error-message-string e))
                 (kill-emacs 1))))
      (kill-emacs 0))' 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out"
    exit 1
  fi
  if printf '%s' "$out" | grep -q "Warning"; then
    warned=1
    printf '%s\n' "$out"
    echo "=== COMPILE WARNINGS PRESENT (STRICT=1) ==="
  else
    echo "COMPILE PASS"
  fi
}

run-ert() {
  local label="$1" selector="$2" out rc
  echo "=== $label ==="
  out="$(SEL1="$selector" "$EMACS" -Q --batch -L . -l "$TEST" --eval '
    (ert-run-tests-batch-and-exit (getenv "SEL1"))' 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out"
    echo "$label FAILED"
    return 1
  fi
  echo "$label PASS"
}

tests() {
  run-ert "TESTS" "$PKG-test-" || exit 2
}

probe() {
  local p="$1"
  local out rc
  echo "=== PROBE: $p ==="
  out="$(SEL1="$PKG-test-" SEL2="probe-" "$EMACS" -Q --batch -L . -l "$TEST" -l "$p" --eval '
    (ert-run-tests-batch-and-exit
     (concat (getenv "SEL1") "\\|" (getenv "SEL2")))' 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out"
    echo "PROBE FAILED"
    exit 3
  fi
  echo "PROBE PASS"
}

finish() {
  if [ "$STRICT" = 1 ] && [ "$warned" -eq 1 ]; then
    echo "EXIT 5: byte-compile warnings (STRICT=1)"
    exit 5
  fi
}

case "${1:-}" in
  -c) compile; finish ;;
  -k) compile; tests; finish ;;
  probe) clean; compile; tests; probe "$2"; finish ;;
  *) clean; compile; tests; finish ;;
esac
