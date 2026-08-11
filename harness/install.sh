#!/usr/bin/env bash
# super-harness install script — wire plugin into Emacs (Doom-aware).
# Usage:
#   ./harness/install.sh            install
#   ./harness/install.sh --uninstall  remove wiring (keeps repo)
# Re-run anytime (idempotent). Symlinks → repo edits live via M-x super-harness-reload.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNIPPET_MARKER=";; === super-harness (managed by harness/install.sh) ==="

# --- Detect Doom 3 (config in ~/.config/doom, emacs home ~/.config/emacs) ---
DOOM_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/doom/config.el"
if [ -f "${DOOM_CFG}" ]; then
  TARGET="${DOOM_CFG}"
  echo "Doom detected: wiring into ${DOOM_CFG}"
else
  # Classic ~/.emacs.d
  TARGET="${HOME}/.emacs.d/init.el"
  mkdir -p "$(dirname "${TARGET}")"
  echo "Classic Emacs: wiring into ${TARGET}"
fi

uninstall() {
  if [ -f "${TARGET}" ]; then
    # Remove from first marker to end-of-super-harness line, inclusive
    awk -v start="${SNIPPET_MARKER}" -v end=";; === end super-harness ===" '
      $0 == start {skip=1}
      skip && $0 == end {skip=0; next}
      !skip' "${TARGET}" > "${TARGET}.tmp" && mv -f "${TARGET}.tmp" "${TARGET}"
    echo "Removed wiring from ${TARGET}"
  fi
  echo "Done."
  exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

# --- Install: idempotent marker-based append ---
if [ -f "${TARGET}" ] && grep -qF "${SNIPPET_MARKER}" "${TARGET}"; then
  echo "Already wired; skipping."
else
  {
    echo ""
    echo "${SNIPPET_MARKER}"
    echo "(add-to-list 'load-path \"${HARNESS_DIR}\")"
    echo "(require 'super-harness)"
    echo "(super-harness-mode 1)"
    echo ";; === end super-harness ==="
  } >> "${TARGET}"
  echo "Wired: ${TARGET}"
fi

echo "Installed."
echo "Restart Emacs (or M-x super-harness-reload)."
