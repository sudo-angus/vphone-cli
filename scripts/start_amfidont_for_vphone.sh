#!/bin/zsh
# start_amfidont_for_vphone.sh — Start amfidont for the current vphone build.
#
# This is the README "Option 2" host workaround packaged for this repo:
# - uses the project path so amfidont covers binaries relevant for the project
# - starts amfidont in daemon mode so signed vphone-cli launches are allowlisted
# - spoofs signatures to be recognized as apple signed for patchless variant
#
# Wrapped in amfidont_supervisor.sh so the bypass survives amfid being
# launchd-recycled (which otherwise kills the worker with
# `RuntimeError: Unexpected process state 10` and silently drops the bypass).
# Run under sudo so the supervisor and worker run as root, and so the sudo
# credential cache is warmed for the later `--tcp-workaround` helper.

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

sudo zsh "${SCRIPT_DIR}/amfidont_supervisor.sh" \
    --python "$PYTHON_BIN" \
    --path "$PROJECT_ROOT"

echo "amfidont started"
