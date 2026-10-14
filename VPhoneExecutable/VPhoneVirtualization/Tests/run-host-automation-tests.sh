#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
out="$root/.build/host-automation-tests"
mkdir -p "$out"
# Compile the real socket/protocol helpers needed by the server and legacy
# adapter, independent of firmware dependencies and bundle builds.
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macos15.0 -module-cache-path "$out/module-cache" \
    -emit-library -static -emit-module -module-name VPhoneCoreKit \
    "$root/VPhoneKit/VPhoneCoreKit/Process/VPhoneUnixSocket.swift" \
    "$root/VPhoneKit/VPhoneCoreKit/Support/VPhoneLegacyGuestSession.swift" \
    -emit-module-path "$out/VPhoneCoreKit.swiftmodule" -o "$out/libVPhoneCoreKit.a"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macos15.0 -module-cache-path "$out/module-cache" \
    -I "$out" -L "$out" -lVPhoneCoreKit \
    "$root/VPhoneExecutable/VPhoneVirtualization/UI/VPhoneHostAutomationServer.swift" \
    "$root/VPhoneExecutable/VPhoneVirtualization/UI/HostDevices/VPhoneScreenRecorder.swift" \
    "$root/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneLegacyGuestControl.swift" \
    "${0:a:h}/HostAutomationServerTests.swift" -o "$out/HostAutomationServerTests"
"$out/HostAutomationServerTests" "$out" "$@"
