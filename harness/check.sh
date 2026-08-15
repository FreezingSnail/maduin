#!/usr/bin/env bash
# check.sh — single entry point: byte-compile + ERT + optional probe.
#
# Usage:
#   ./check.sh                     # clean + compile + tests
#   ./check.sh -c                  # compile only
#   ./check.sh -k                  # skip clean (keep .elc)
#   ./check.sh probe probes/foo.el # + probe file (exploratory ERT tests)
#
# Exit codes:
#   0  green
#   1  byte-compile error (fail-fast; tests skipped)
#   2  test failure
#   3  probe failure
#   5  byte-compile warnings present (STRICT=1; reported AFTER tests)
#
# Config: PKG, TEST, FILES (dependency order, deps first).

set -uo pipefail

EMACS="${EMACS:-emacs}"
PKG="maduin"                    # base package name (no .el)
TEST="${PKG}-test"              # test library stem
STRICT="${STRICT:-1}"           # 1 = warnings raise exit 5 after tests

# Compile order = dependency order. Deps first. Keep in sync with requires.
FILES=(
  "config.el"
  "maduin-logging.el"
  "maduin-config.el"
  "maduin-bd-bridge.el"
  "maduin-session.el"
  "maduin-brain.el"
  "maduin-workspace.el"
  "maduin-terminal.el"
  "maduin-gate.el"
  "maduin-agent.el"
  "maduin-pipeline.el"
  "maduin-review.el"
  "maduin-handoff.el"
  "maduin-dispatch.el"
  "maduin-cockpit.el"
  "maduin-designer.el"
  "maduin-concierge.el"
  "maduin-repairer.el"
  "maduin.el"
  "maduin-test.el"
)

cd "$(dirname "${BASH_SOURCE[0]}")"   # operate from script dir (tests use relative paths)

warned=0

clean()   { rm -f ./*.elc; }

compile() {
  echo "=== COMPILE ==="
  local out rc
  FILES_JOINED="$(IFS=:; printf '%s' "${FILES[*]}")"
  out="$(FILES_JOINED="$FILES_JOINED" "$EMACS" -Q --batch -L . --eval '
    (let ((files (split-string (or (getenv "FILES_JOINED") "") ":")))
      ;; Pre-load sibling sources (dep order) so cross-file functions/vars
      ;; resolve at compile time — avoids false "not known to be defined".
      (dolist (f files)
        (unless (string-suffix-p "-test.el" f)
          (condition-case e
              (load (file-name-sans-extension f) nil t)
            (error (message "LOAD SKIP %s: %s" f (error-message-string e))))))
      ;; Compile each file. Hard error → kill-emacs 1 (fail fast).
      (dolist (f files)
        (condition-case e
            (byte-compile-file f)
          (error (message "COMPILE ERROR %s: %s" f (error-message-string e))
                 (kill-emacs 1))))
      (kill-emacs 0))' 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  [ "$rc" -ne 0 ] && exit 1              # compile error: stop, skip tests
  if printf '%s' "$out" | grep -q "Warning"; then
    warned=1                             # warnings: record, continue to tests
    echo "=== COMPILE WARNINGS PRESENT (STRICT=1) ==="
  fi
}

tests() {
  echo "=== TESTS ==="
  SEL1="$PKG-test-" "$EMACS" -Q --batch -L . -l "$TEST" --eval '
    (ert-run-tests-batch-and-exit (getenv "SEL1"))' \
    || { echo "TESTS FAILED"; exit 2; }
}

probe() {
  local p="$1"; shift
  echo "=== PROBE: $p ==="
  SEL1="$PKG-test-" SEL2="probe-" "$EMACS" -Q --batch -L . -l "$TEST" -l "$p" --eval '
    (ert-run-tests-batch-and-exit (concat (getenv "SEL1") "\\|" (getenv "SEL2")))' \
    || { echo "PROBE FAILED"; exit 3; }
}

finish() {
  if [ "$STRICT" = 1 ] && [ "$warned" -eq 1 ]; then
    echo "EXIT 5: byte-compile warnings (STRICT=1)"
    exit 5
  fi
  exit 0
}

case "${1:-}" in
  -c)      compile; finish ;;
  -k)      compile; tests; finish ;;
  probe)   clean; compile; tests; probe "$2"; finish ;;
  *)       clean; compile; tests; finish ;;
esac
