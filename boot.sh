#!/usr/bin/env zsh
# boot.sh — Friendly wrapper around `make boot` for team use.
#
# Handles the host-side prerequisite that is easy to forget:
#   amfidont must already be running before boot, otherwise AMFI silently
#   kills the signed vphone-cli binary with a confusing error.
#
# Side benefit: `make amfidont_allow_vphone` triggers sudo and warms its
# credential cache, so when vphone-cli later runs `sudo` for the
# `--tcp-workaround` privileged helper, it goes through silently.
#
# Usage:
#   ./boot.sh                       # boot with the default safe flags
#   ./boot.sh --install-ipa foo.ipa # extra flags are forwarded to `make boot`
#
# Always-on flags passed to `make boot`:
#   --tcp-workaround    (host TCP proxy workaround for VPN-broken NAT)
#   --software-keyboard (use iOS software keyboard instead of USB keyboard)

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'; CYAN=$'\e[36m'
else
    BOLD=""; DIM=""; RESET=""; CYAN=""
fi

section() {
    print -- ""
    print -- "${BOLD}${CYAN}══ $1 ══${RESET}"
}

DEFAULT_FLAGS=(--tcp-workaround --software-keyboard)
USER_FLAGS=("$@")
ALL_FLAGS=("${DEFAULT_FLAGS[@]}" "${USER_FLAGS[@]}")

section "第 1/2 步"
print -- "$ ${BOLD}make amfidont_allow_vphone${RESET}"
make amfidont_allow_vphone

# Refresh sudo so vphone-cli's --tcp-workaround helper inherits a warm
# credential cache and doesn't re-prompt mid-boot. Silent if step 1's
# cache is still valid.
sudo -v

section "第 2/2 步"
print -- "$ ${BOLD}make boot EXTRA_ARGS=\"${ALL_FLAGS[*]}\"${RESET}"
exec make boot EXTRA_ARGS="${ALL_FLAGS[*]}"
