#!/bin/zsh
# amfidont_supervisor.sh — Keep the amfidont AMFI bypass alive for this repo.
#
# Why this exists: amfidont attaches an lldb session to /usr/libexec/amfid and
# patches each signature check. amfid is launchd-managed and gets idle-recycled,
# and when it does the worker's lldb session sees the target in eStateExited
# (state 10) and bails with `RuntimeError: Unexpected process state 10` — the
# amfidont daemon process then exits and the bypass is silently gone. Anything
# that needs the bypass at *launch time* (the signed vphone-cli binary, spawned
# tools, the patchless variant) starts failing until amfidont is restarted by
# hand.
#
# This watchdog polls for a live worker and relaunches it whenever amfid is
# recycled, so the bypass survives without intervention. It self-daemonizes:
# the foreground invocation forks a detached loop, prints its pid, and returns
# promptly, so callers (boot.sh / the manager) don't block.
#
# When run as root (CLI flow, `make amfidont_allow_vphone`) it launches the
# worker directly. When run as the user (the GUI manager) it launches via
# `sudo -n`, relying on the manager's scoped NOPASSWD sudoers rule — so this
# needs no new privilege and no re-authorization.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"

PYTHON_BIN=""
POLL_INTERVAL=2     # seconds between worker liveness checks
SETTLE=2            # grace after a (re)launch before re-checking

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python) PYTHON_BIN="$2"; shift 2 ;;
    --path)   PROJECT_ROOT="$2"; shift 2 ;;
    --log)    AMFIDONT_SUPERVISOR_LOG="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

LOG="${AMFIDONT_SUPERVISOR_LOG:-${TMPDIR:-/tmp}/vphone-amfidont-supervisor.log}"

# Resolve a python3 that can `import amfidont`, mirroring
# start_amfidont_for_vphone.sh. The manager passes --python so the inner
# `sudo -n` command matches its pinned sudoers rule byte-for-byte.
if [[ -z "$PYTHON_BIN" ]]; then
  for candidate in "$(xcrun -f python3 2>/dev/null || true)" "$(command -v python3 || true)"; do
    [[ -n "$candidate" ]] || continue
    if "$candidate" -c 'import amfidont' &>/dev/null; then
      PYTHON_BIN="$candidate"
      break
    fi
  done
fi
if [[ -z "$PYTHON_BIN" ]]; then
  echo "amfidont not found (xcrun python3 -m pip install -U amfidont)" >&2
  exit 1
fi

# The long-lived worker's argv — `python -m amfidont --spoof-apple --path REPO`
# (no `daemon` subcommand; that's the launcher). We match this to tell a live
# worker apart from the launcher and from this supervisor.
worker_alive() {
  pgrep -fl amfidont 2>/dev/null \
    | grep -F -- "--path $PROJECT_ROOT" \
    | grep -v -- 'supervisor' \
    | grep -vq -- ' daemon '
}

launch_worker() {
  if [[ $EUID -eq 0 ]]; then
    "$PYTHON_BIN" -m amfidont daemon --path "$PROJECT_ROOT" --spoof-apple
  else
    sudo -n "$PYTHON_BIN" -m amfidont daemon --path "$PROJECT_ROOT" --spoof-apple
  fi
}

# Self-daemonize, leaving the foreground invocation to report the pid and
# return. macOS has no `setsid`; `nohup … &` plus the parent exiting is enough —
# the child ignores SIGHUP and reparents to launchd, so the watchdog outlives
# both this shell and the (Swift) process that launched it.
if [[ "${_AMFIDONT_SUP_CHILD:-}" != "1" ]]; then
  # Refuse to stack a second supervisor on the same repo.
  if pgrep -fl amfidont_supervisor 2>/dev/null | grep -qF -- "--path $PROJECT_ROOT"; then
    echo "amfidont supervisor already running for $PROJECT_ROOT"
    exit 0
  fi
  _AMFIDONT_SUP_CHILD=1 nohup "$0" --python "$PYTHON_BIN" --path "$PROJECT_ROOT" --log "$LOG" \
    >>"$LOG" 2>&1 </dev/null &
  echo "amfidont supervisor started (pid: $!)"
  exit 0
fi

trap 'exit 0' TERM INT

while true; do
  if ! worker_alive; then
    launch_worker || true
    sleep "$SETTLE"
  fi
  sleep "$POLL_INTERVAL"
done
