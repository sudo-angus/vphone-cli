#!/bin/zsh
set -euo pipefail

# Transparent proxy helper for vphone VM.
# Adds pf redirect rules so all VM TCP traffic goes through vm_tproxy.py.
#
# Usage:
#   sudo ./scripts/vm_tproxy_start.sh                    # start (manual)
#   sudo ./scripts/vm_tproxy_start.sh stop                # stop
#   sudo WATCH_PID=$$ ./scripts/vm_tproxy_start.sh start  # daemon mode:
#       cleans up automatically when WATCH_PID is no longer alive
#       (used by vphone-cli's --tcp-workaround integration)

SCRIPT_DIR="${0:a:h}"
ANCHOR="${ANCHOR:-vphone_tproxy}"
LISTEN_PORT="${LISTEN_PORT:-3129}"
LISTEN_ADDR="${LISTEN_ADDR:-}"
PF_INTERFACE="${PF_INTERFACE:-}"
PID_FILE="${PID_FILE:-/tmp/${ANCHOR}.pid}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-30}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
WATCH_PID="${WATCH_PID:-}"
WATCH_INTERVAL="${WATCH_INTERVAL:-2}"
proxy_pid=""
watchdog_pid=""

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "[tproxy] run with sudo/root" >&2
        exit 1
    fi
}

detect_pf_interface() {
    if [[ -n "$PF_INTERFACE" ]]; then
        echo "$PF_INTERFACE"
        return
    fi

    local detected
    detected="$(
        ifconfig | awk -v target="$LISTEN_ADDR" '
            /^[^ \t]/ {
                iface = $1
                sub(/:$/, "", iface)
            }
            $1 == "inet" && $2 == target {
                print iface
                exit
            }
        '
    )"

    if [[ -z "$detected" ]]; then
        echo "[tproxy] failed to find an interface with address $LISTEN_ADDR; set PF_INTERFACE=..." >&2
        exit 1
    fi

    echo "$detected"
}

detect_listen_addr_for_interface() {
    local target_interface="$1"
    local detected
    detected="$(
        ifconfig "$target_interface" 2>/dev/null | awk '
            $1 == "inet" {
                print $2
                exit
            }
        '
    )"

    if [[ -z "$detected" ]]; then
        echo "[tproxy] interface '$target_interface' has no IPv4 address; set LISTEN_ADDR=..." >&2
        exit 1
    fi

    echo "$detected"
}

detect_vmnet_bridge_endpoint() {
    ifconfig | awk '
        /^[^ \t]/ {
            if (iface != "" && ipv4 != "" && has_vmenet) {
                found = 1
                print iface "|" ipv4
                exit
            }
            iface = $1
            sub(/:$/, "", iface)
            ipv4 = ""
            has_vmenet = 0
        }
        $1 == "inet" {
            ipv4 = $2
        }
        $1 == "member:" && $2 ~ /^vmenet[0-9]+$/ {
            has_vmenet = 1
        }
        END {
            if (!found && iface != "" && ipv4 != "" && has_vmenet) {
                print iface "|" ipv4
            }
        }
    '
}

resolve_listen_endpoint() {
    local resolved_interface="$PF_INTERFACE"
    local resolved_addr="$LISTEN_ADDR"
    local auto_endpoint=""

    if [[ -n "$resolved_interface" && -n "$resolved_addr" ]]; then
        echo "$resolved_interface|$resolved_addr"
        return
    fi

    if [[ -n "$resolved_addr" ]]; then
        resolved_interface="$(detect_pf_interface)"
        echo "$resolved_interface|$resolved_addr"
        return
    fi

    if [[ -n "$resolved_interface" ]]; then
        resolved_addr="$(detect_listen_addr_for_interface "$resolved_interface")"
        echo "$resolved_interface|$resolved_addr"
        return
    fi

    auto_endpoint="$(detect_vmnet_bridge_endpoint)"
    if [[ -n "$auto_endpoint" ]]; then
        echo "$auto_endpoint"
        return
    fi

    echo "[tproxy] failed to auto-detect the Virtualization shared bridge; set LISTEN_ADDR=... and/or PF_INTERFACE=..." >&2
    exit 1
}

load_anchor() {
    local pf_interface="$1"
    echo "[tproxy] loading pf anchor '$ANCHOR' on interface '$pf_interface'..."
    printf '%s\n' \
        "rdr pass on $pf_interface proto tcp from ($pf_interface:network) to any -> $LISTEN_ADDR port $LISTEN_PORT" \
        | pfctl -a "$ANCHOR" -f -
    pfctl -e 2>/dev/null || true
}

flush_anchor() {
    echo "[tproxy] tearing down pf anchor '$ANCHOR'..."
    echo "" | pfctl -a "$ANCHOR" -f - 2>/dev/null || true
}

kill_proxy() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid="$(<"$PID_FILE")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
}

kill_watchdog() {
    if [[ -n "$watchdog_pid" ]] && kill -0 "$watchdog_pid" 2>/dev/null; then
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi
    watchdog_pid=""
}

cleanup() {
    local exit_code="${1:-$?}"
    trap - EXIT INT TERM
    kill_watchdog
    kill_proxy
    flush_anchor
    echo "[tproxy] stopped."
    exit "$exit_code"
}

status() {
    local running="no"
    local pid=""
    if [[ -f "$PID_FILE" ]]; then
        pid="$(<"$PID_FILE")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            running="yes"
        fi
    fi

    echo "[tproxy] pid_file=$PID_FILE"
    echo "[tproxy] proxy_running=$running${pid:+ (pid=$pid)}"
    pfctl -a "$ANCHOR" -s rules 2>/dev/null || true
}

start() {
    require_root

    if [[ -f "$PID_FILE" ]]; then
        local existing_pid
        existing_pid="$(<"$PID_FILE")"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            echo "[tproxy] already running (pid=$existing_pid)" >&2
            exit 1
        fi
        rm -f "$PID_FILE"
    fi

    local endpoint
    local pf_interface
    endpoint="$(resolve_listen_endpoint)"
    pf_interface="${endpoint%%|*}"
    LISTEN_ADDR="${endpoint#*|}"
    echo "[tproxy] using listen_addr=$LISTEN_ADDR interface=$pf_interface"
    load_anchor "$pf_interface"

    echo "[tproxy] pf anchor loaded. starting proxy..."
    trap 'cleanup $?' EXIT INT TERM
    "$PYTHON_BIN" "$SCRIPT_DIR/vm_tproxy.py" \
        --listen-addr "$LISTEN_ADDR" \
        --listen-port "$LISTEN_PORT" \
        --connect-timeout "$CONNECT_TIMEOUT" &
    proxy_pid="$!"
    echo "$proxy_pid" >"$PID_FILE"

    if [[ -n "$WATCH_PID" ]]; then
        if ! kill -0 "$WATCH_PID" 2>/dev/null; then
            echo "[tproxy] WATCH_PID=$WATCH_PID is not alive at startup; aborting" >&2
            exit 1
        fi
        echo "[tproxy] watchdog: tracking parent pid=$WATCH_PID (interval=${WATCH_INTERVAL}s)"
        (
            while kill -0 "$WATCH_PID" 2>/dev/null; do
                sleep "$WATCH_INTERVAL"
            done
            echo "[tproxy] parent pid=$WATCH_PID exited; tearing down" >&2
            kill -TERM "$proxy_pid" 2>/dev/null || true
        ) &
        watchdog_pid="$!"
    fi

    wait "$proxy_pid" 2>/dev/null || true
}

stop() {
    require_root
    kill_proxy
    flush_anchor
    echo "[tproxy] stopped."
}

case "${1:-start}" in
    stop)  stop ;;
    status) status ;;
    start) start ;;
    *)     echo "Usage: $0 [start|stop|status]"; exit 1 ;;
esac
