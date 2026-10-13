#!/bin/zsh
# vphone-tier: build
set -euo pipefail
root="$(cd "${0:a:h}/../../.." && pwd)"
out="$root/.build/attitude-dial-tests"
mkdir -p "$out"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macos15.0 -module-cache-path "$out/module-cache" \
    "$root/VPhoneExecutable/VPhoneVirtualization/UI/UserInterface/VPhoneLocalization.swift" \
    "$root/VPhoneExecutable/VPhoneVirtualization/UI/UserInterface/Panels/Motion/"*.swift \
    "${0:a:h}/AttitudeDialTests.swift" -o "$out/AttitudeDialTests"
"$out/AttitudeDialTests" "$@"
