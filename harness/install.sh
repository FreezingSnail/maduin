#!/usr/bin/env bash
# super-harness install script — symlink plugin into Emacs, wire init.
# Usage: ./harness/install.sh
# Re-run anytime (idempotent). Symlinks → edits in repo live-reload via M-x super-harness-reload.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMACS_D="${HOME}/.emacs.d"
PLUGIN_DIR="${EMACS_D}/super-harness"
INIT="${EMACS_D}/init.el"

mkdir -p "${EMACS_D}"

# Symlink plugin dir (force, non-interactive)
ln -sfn "${HARNESS_DIR}" "${PLUGIN_DIR}"

# Append init snippet idempotently
SNIPPET_MARKER=";; === super-harness (managed by harness/install.sh) ==="
if [ -f "${INIT}" ] && grep -qF "${SNIPPET_MARKER}" "${INIT}"; then
  echo "init.el already wired; skipping."
else
  {
    echo ""
    echo "${SNIPPET_MARKER}"
    echo "(add-to-list 'load-path \"${PLUGIN_DIR}\")"
    echo "(require 'super-harness)"
    echo "(super-harness-mode 1)"
    echo ";; === end super-harness ==="
  } >> "${INIT}"
  echo "init.el wired."
fi

echo "Installed: ${PLUGIN_DIR} → ${HARNESS_DIR}"
echo "Restart Emacs, or M-x eval-buffer on ${INIT}, or M-x super-harness-reload to load now."
