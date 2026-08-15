# probes/ — exploratory ERT tests

Temporary questions about Emacs/plugin behavior. **Not** part of the
permanent test gate — that's `maduin-test-*` in `maduin-test.el`.

## Rules (agent feedback loop)

1. After every source edit → run `./check.sh`. Read all output in **one turn**.
2. Unknown behavior → append a `probe-*` ERT test here, run
   `./check.sh probe probes/<topic>.el`. **Never inline `--eval`** — batch all
   questions into one probe file, run once, read every answer.
3. A probe proves a real invariant → rename it `maduin-test-*` and move it into
   `maduin-test.el` to become a permanent gate.

## Probe file shape

```elisp
;;; probes/defcustom-group.el --- defcustom :group forward-ref probe
(ert-deftest probe-defcustom-group ()
  (should (equal (get 'maduin-g 'custom-group)
                 '((maduin-test-x custom-variable)))))
```

- Loaded with `-l maduin-test -l <probe>` → full access to test fixtures/helpers.
- Prefix every test `probe-` so `./check.sh probe` selects it.
- Uses `should` (real assertion), not just `princ` — a failing probe exits 3.

## Exit codes

| code | meaning |
|---|---|
| 0 | green |
| 1 | compile error (fail-fast) |
| 2 | test failure |
| 3 | probe failure |
| 5 | byte-compile warnings (STRICT=1, after tests) |
