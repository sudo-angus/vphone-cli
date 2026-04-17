#!/bin/zsh
# start_amfidont_for_vphone.sh — Start amfidont for the current vphone build.
#
# This is the README "Option 2" host workaround packaged for this repo:
# - uses the project path so amfidont covers binaries relevant for the project
# - starts amfidont in daemon mode so signed vphone-cli launches are allowlisted
# - spoofs signatures to be recognized as apple signed for patchless variant

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"

# Resolve a python3 that has the `amfidont` module available.
# Upstream's install hint is `xcrun python3 -m pip install -U amfidont`,
# which drops the entry-point under ~/Library/Python/X.Y/bin (not on PATH and
# not discoverable via `xcrun --find`). Invoke the module directly so we
# don't depend on the shim's location.
PYTHON_BIN=""
for candidate in "$(xcrun -f python3 2>/dev/null || true)" "$(command -v python3 || true)"; do
  [[ -n "$candidate" ]] || continue
  if "$candidate" -c 'import amfidont' &>/dev/null; then
    PYTHON_BIN="$candidate"
    break
  fi
done

if [[ -z "$PYTHON_BIN" ]]; then
  echo "amfidont not found" >&2
  echo "Install it first: xcrun python3 -m pip install -U amfidont" >&2
  exit 1
fi

sudo "$PYTHON_BIN" -m amfidont daemon \
    --path "$PROJECT_ROOT" \
    --spoof-apple \
    >/dev/null 2>&1

echo "amfidont started"
