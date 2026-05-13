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
#   --tcp-workaround                  (host TCP proxy workaround for VPN-broken NAT)
#   --software-keyboard               (use iOS software keyboard instead of USB keyboard)
#   --usbmux-forward 2222:22222       (SSH/dropbear)
#   --usbmux-forward 5910:5910        (rpc-project)

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
    CYAN=$'\e[36m'; GREEN=$'\e[32m'
else
    BOLD=""; DIM=""; RESET=""; CYAN=""; GREEN=""
fi

section() {
    print -- ""
    print -- "${BOLD}${CYAN}══ $1 ══${RESET}"
}

DEFAULT_FLAGS=(
    --tcp-workaround
    --software-keyboard
    --usbmux-forward 2222:22222
    --usbmux-forward 5910:5910
)
USER_FLAGS=("$@")
ALL_FLAGS=("${DEFAULT_FLAGS[@]}" "${USER_FLAGS[@]}")

print_item() {
    print -- "  ${GREEN}•${RESET} $1"
}

print_forward() {
    local spec="$1"
    local normalized="${spec/=/:}"
    local local_port="${normalized%%:*}"
    local guest_port="${normalized#*:}"
    local label="TCP 端口转发"

    if [[ "$local_port" == "2222" && "$guest_port" == "22222" ]]; then
        label="SSH / dropbear"
    elif [[ "$guest_port" == "22" ]]; then
        label="SSH / OpenSSH"
    elif [[ "$local_port" == "5910" && "$guest_port" == "5910" ]]; then
        label="rpc-project"
    fi

    print_item "${label}: ${BOLD}127.0.0.1:${local_port}${RESET} → guest:${guest_port}"
}

print_user_flags_summary() {
    if (( ${#USER_FLAGS[@]} == 0 )); then
        print -- "  ${DIM}没有用户追加参数。${RESET}"
        return
    fi

    local -a passthrough=()
    local i=1
    local flag value
    while (( i <= ${#USER_FLAGS[@]} )); do
        flag="${USER_FLAGS[$i]}"
        case "$flag" in
            --install-ipa)
                (( i++ ))
                value="${USER_FLAGS[$i]:-<missing>}"
                print_item "启动后自动安装应用包: ${BOLD}${value}${RESET}"
                ;;
            --install-ipa=*)
                value="${flag#--install-ipa=}"
                print_item "启动后自动安装应用包: ${BOLD}${value}${RESET}"
                ;;
            --usbmux-forward)
                (( i++ ))
                value="${USER_FLAGS[$i]:-<missing>}"
                print_forward "$value"
                ;;
            --usbmux-forward=*)
                value="${flag#--usbmux-forward=}"
                print_forward "$value"
                ;;
            --usbmux-udid)
                (( i++ ))
                value="${USER_FLAGS[$i]:-<missing>}"
                print_item "指定 usbmux 目标设备: ${BOLD}${value}${RESET}"
                ;;
            --usbmux-udid=*)
                value="${flag#--usbmux-udid=}"
                print_item "指定 usbmux 目标设备: ${BOLD}${value}${RESET}"
                ;;
            --socks5-port)
                (( i++ ))
                value="${USER_FLAGS[$i]:-<missing>}"
                print_item "暴露 guest 网络 SOCKS5 代理: ${BOLD}127.0.0.1:${value}${RESET}"
                ;;
            --socks5-port=*)
                value="${flag#--socks5-port=}"
                print_item "暴露 guest 网络 SOCKS5 代理: ${BOLD}127.0.0.1:${value}${RESET}"
                ;;
            --kernel-debug-port)
                (( i++ ))
                value="${USER_FLAGS[$i]:-<missing>}"
                print_item "固定 kernel GDB debug stub 端口: ${BOLD}127.0.0.1:${value}${RESET}"
                ;;
            --kernel-debug-port=*)
                value="${flag#--kernel-debug-port=}"
                print_item "固定 kernel GDB debug stub 端口: ${BOLD}127.0.0.1:${value}${RESET}"
                ;;
            --variant)
                (( i++ ))
                value="${USER_FLAGS[$i]:-<missing>}"
                print_item "固件运行变体: ${BOLD}${value}${RESET}"
                ;;
            --variant=*)
                value="${flag#--variant=}"
                print_item "固件运行变体: ${BOLD}${value}${RESET}"
                ;;
            --tcp-workaround)
                print_item "Host TCP 透明代理绕行: ${BOLD}已启用${RESET}"
                ;;
            --software-keyboard)
                print_item "iOS 软件键盘模式: ${BOLD}已启用${RESET}"
                ;;
            --no-vphoned)
                print_item "vphoned 控制通道: ${BOLD}禁用${RESET}"
                ;;
            *)
                passthrough+=("$flag")
                ;;
        esac
        (( i++ ))
    done

    if (( ${#passthrough[@]} > 0 )); then
        print_item "其他 vphone-cli 参数: ${BOLD}${passthrough[*]}${RESET}"
    fi
}

section "本次启动配置"
print -- "${BOLD}默认启用${RESET}"
print_item "Host TCP 透明代理绕行: ${BOLD}已启用${RESET}"
print_item "iOS 软件键盘模式: ${BOLD}已启用${RESET}"
print_forward "2222:22222"
print_forward "5910:5910"
print -- ""
print -- "${BOLD}用户追加${RESET}"
print_user_flags_summary

section "第 1/2 步"
print -- "$ ${BOLD}make amfidont_allow_vphone${RESET}"
make amfidont_allow_vphone

# Refresh sudo so vphone-cli's --tcp-workaround helper inherits a warm
# credential cache and doesn't re-prompt mid-boot. Silent if step 1's
# cache is still valid.
sudo -v

section "第 2/2 步"
print -- "${DIM}将调用 make boot；完整参数已按上方配置摘要展开。${RESET}"
exec make boot EXTRA_ARGS="${ALL_FLAGS[*]}"
