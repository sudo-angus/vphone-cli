#!/bin/zsh
set -euo pipefail
# Requests use loopback and random ports; no VM, VPN or guest is needed.
daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-socks5-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT
/usr/bin/xcrun --sdk macosx clang -Wall -Wextra -Werror -fsanitize=address,undefined \
    "$daemon/Native/vphoned_socks5.c" "$daemon/Tests/Socks5Tests.c" -o "$temporary/socks5-tests"
"$temporary/socks5-tests"
/usr/bin/xcrun --sdk macosx clang -Wall -Wextra -Werror -c \
    "$daemon/Native/vphoned_socks5.c" -o "$temporary/socks5.o"
# Import only the portable native interface, without guest UIKit dependencies.
print -r -- "module VphonedNative { header \"$daemon/Native/Include/VphonedSocks5.h\" export * }" > "$temporary/module.modulemap"
/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -I "$temporary" -module-cache-path "$temporary/module-cache" \
    "$daemon/Daemon/GuestSocks5.swift" "$daemon/Tests/Socks5ConfigurationTests.swift" \
    "$temporary/socks5.o" -o "$temporary/socks5-configuration-tests"
"$temporary/socks5-configuration-tests"
