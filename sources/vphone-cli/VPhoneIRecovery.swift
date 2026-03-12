import Foundation
import MobileRestoreCore

enum VPhoneIRecovery {
    static func sendDFUFile(path: String, ecid: UInt64?) throws {
        try sendFile(
            path: path,
            ecid: ecid,
            mode: Int32(VPHONE_IRECV_MODE_DFU),
            options: UInt32(VPHONE_IRECV_SEND_OPT_DFU_NOTIFY_FINISH),
            action: "DFU file transfer"
        )
    }

    static func sendRecoveryFile(path: String, ecid: UInt64?) throws {
        try sendFile(
            path: path,
            ecid: ecid,
            mode: Int32(VPHONE_IRECV_MODE_RECOVERY),
            options: 0,
            action: "recovery file transfer"
        )
    }

    static func sendRecoveryCommand(_ command: String, ecid: UInt64?) throws {
        let result = command.withCString { commandPtr in
            vphone_irecv_send_command(
                commandPtr,
                ecid ?? 0,
                ecid == nil ? 0 : 1,
                Int32(VPHONE_IRECV_MODE_RECOVERY)
            )
        }
        try requireSuccess(result, action: "recovery command '\(command)'")
    }

    static func sendRecoveryCommandBreq(_ command: String, request: UInt8 = 1, ecid: UInt64?) throws {
        let result = command.withCString { commandPtr in
            vphone_irecv_send_command_breq(
                commandPtr,
                request,
                ecid ?? 0,
                ecid == nil ? 0 : 1,
                Int32(VPHONE_IRECV_MODE_RECOVERY)
            )
        }
        try requireSuccess(result, action: "recovery command '\(command)' (breq)")
    }

    static func waitForRecovery(ecid: UInt64?, timeout: TimeInterval = 20) throws {
        let milliseconds = max(Int(timeout * 1000.0), 0)
        let result = vphone_irecv_wait_for_mode(
            ecid ?? 0,
            ecid == nil ? 0 : 1,
            Int32(VPHONE_IRECV_MODE_RECOVERY),
            Int32(milliseconds)
        )
        try requireSuccess(result, action: "wait for recovery mode")
    }

    static func openRecoverySession(ecid: UInt64?, attempts: Int32 = 10) throws -> RecoverySession {
        var error: Int32 = -1
        let handle = vphone_irecv_open_session(
            ecid ?? 0,
            ecid == nil ? 0 : 1,
            Int32(VPHONE_IRECV_MODE_RECOVERY),
            attempts,
            &error
        )
        guard let handle else {
            try requireSuccess(error, action: "open recovery session")
            throw VPhoneHostError.invalidArgument("open recovery session failed for an unknown reason")
        }
        return RecoverySession(handle: handle)
    }
}

final class RecoverySession {
    private var handle: UnsafeMutableRawPointer?

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        close()
    }

    func sendFile(path: String, options: UInt32 = 0) throws {
        let result = path.withCString { pathPtr in
            vphone_irecv_session_send_file(handle, pathPtr, options)
        }
        try VPhoneIRecovery.requireSuccess(result, action: "recovery file transfer")
    }

    func sendCommand(_ command: String) throws {
        let result = command.withCString { commandPtr in
            vphone_irecv_session_send_command(handle, commandPtr)
        }
        try VPhoneIRecovery.requireSuccess(result, action: "recovery command '\(command)'")
    }

    func sendCommandBreq(_ command: String, request: UInt8 = 1) throws {
        let result = command.withCString { commandPtr in
            vphone_irecv_session_send_command_breq(handle, commandPtr, request)
        }
        try VPhoneIRecovery.requireSuccess(result, action: "recovery command '\(command)' (breq)")
    }

    func usbControlTransfer(
        requestType: UInt8 = 0x21,
        request: UInt8 = 1,
        value: UInt16 = 0,
        index: UInt16 = 0,
        timeoutMilliseconds: Int32 = 5_000,
        allowFailure: Bool = false
    ) throws {
        let result = vphone_irecv_session_usb_control_transfer(
            handle,
            requestType,
            request,
            value,
            index,
            timeoutMilliseconds
        )
        if !allowFailure {
            try VPhoneIRecovery.requireSuccess(result, action: "recovery usb control transfer")
        }
    }

    func close() {
        guard let handle else { return }
        vphone_irecv_close_session(handle)
        self.handle = nil
    }
}

private extension VPhoneIRecovery {
    static func sendFile(
        path: String,
        ecid: UInt64?,
        mode: Int32,
        options: UInt32,
        action: String
    ) throws {
        let result = path.withCString { pathPtr in
            vphone_irecv_send_file(
                pathPtr,
                ecid ?? 0,
                ecid == nil ? 0 : 1,
                mode,
                options
            )
        }
        try requireSuccess(result, action: action)
    }

    static func requireSuccess(_ result: Int32, action: String) throws {
        guard result == 0 else {
            let detail: String
            if let errorPtr = vphone_irecv_error_string(result) {
                detail = String(cString: errorPtr)
            } else {
                detail = "unknown error"
            }
            throw VPhoneHostError.invalidArgument("\(action) failed: \(detail) (\(result))")
        }
    }
}
