import Darwin
import Foundation
import IOKit
import MachO

private enum MobileDeviceImage {
    static let frameworkPath = "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
    static let knownExport = "_AMRecoveryModeDeviceCreateWithIOService"

    static let symbolTable: [String: UInt64] = loadSymbolTable()

    static func exported<T>(_ name: String) -> T? {
        guard let handle = dlopen(frameworkPath, RTLD_NOW),
              let raw = dlsym(handle, name)
        else {
            return nil
        }
        return unsafeBitCast(raw, to: T.self)
    }

    static func local<T>(_ name: String) -> T? {
        guard let vmaddr = symbolTable[name],
              let baseAddress = imageBaseAddress()
        else {
            return nil
        }
        let raw = baseAddress.advanced(by: Int(vmaddr))
        return unsafeBitCast(raw, to: T.self)
    }

    static func imageBaseAddress() -> UnsafeMutableRawPointer? {
        guard let handle = dlopen(frameworkPath, RTLD_NOW),
              let exported = dlsym(handle, knownExport)
        else {
            return nil
        }
        var info = Dl_info()
        guard dladdr(exported, &info) != 0, let base = info.dli_fbase else {
            return nil
        }
        return UnsafeMutableRawPointer(mutating: base)
    }

    static func loadSymbolTable() -> [String: UInt64] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: frameworkPath)) else {
            return [:]
        }

        let slice: (offset: Int, size: Int)
        let magic = data.readUInt32BE(at: 0)
        if magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64 {
            guard let selected = selectFatSlice(in: data, magic: magic) else {
                return [:]
            }
            slice = selected
        } else {
            slice = (0, data.count)
        }

        return parseMachOSymbols(in: data, sliceOffset: slice.offset, sliceSize: slice.size)
    }

    static func selectFatSlice(in data: Data, magic: UInt32) -> (offset: Int, size: Int)? {
        let is64 = magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64
        let archCount = Int(data.readUInt32BE(at: 4))
        let entrySize = is64 ? 32 : 20
        let hostCPUType: cpu_type_t = {
            #if arch(x86_64)
            CPU_TYPE_X86_64
            #elseif arch(arm64)
            CPU_TYPE_ARM64
            #else
            CPU_TYPE_ANY
            #endif
        }()

        var best: (offset: Int, size: Int)?
        for index in 0..<archCount {
            let entryOffset = 8 + (index * entrySize)
            let cpuType = cpu_type_t(bitPattern: data.readUInt32BE(at: entryOffset))
            let offset: Int
            let size: Int
            if is64 {
                offset = Int(data.readUInt64BE(at: entryOffset + 8))
                size = Int(data.readUInt64BE(at: entryOffset + 16))
            } else {
                offset = Int(data.readUInt32BE(at: entryOffset + 8))
                size = Int(data.readUInt32BE(at: entryOffset + 12))
            }
            if cpuType == hostCPUType {
                return (offset, size)
            }
            if best == nil {
                best = (offset, size)
            }
        }
        return best
    }

    static func parseMachOSymbols(in data: Data, sliceOffset: Int, sliceSize: Int) -> [String: UInt64] {
        guard sliceOffset + MemoryLayout<mach_header_64>.size <= data.count else {
            return [:]
        }
        let headerMagic = data.readUInt32LE(at: sliceOffset)
        guard headerMagic == MH_MAGIC_64 else {
            return [:]
        }

        let loadCommandCount = Int(data.readUInt32LE(at: sliceOffset + 16))
        var commandOffset = sliceOffset + MemoryLayout<mach_header_64>.size
        var symoff = 0
        var nsyms = 0
        var stroff = 0
        var strsize = 0

        for _ in 0..<loadCommandCount {
            guard commandOffset + 8 <= data.count else { return [:] }
            let command = data.readUInt32LE(at: commandOffset)
            let size = Int(data.readUInt32LE(at: commandOffset + 4))
            guard size > 0, commandOffset + size <= data.count else { return [:] }
            if command == LC_SYMTAB {
                symoff = Int(data.readUInt32LE(at: commandOffset + 8))
                nsyms = Int(data.readUInt32LE(at: commandOffset + 12))
                stroff = Int(data.readUInt32LE(at: commandOffset + 16))
                strsize = Int(data.readUInt32LE(at: commandOffset + 20))
                break
            }
            commandOffset += size
        }

        guard nsyms > 0 else { return [:] }
        let symbolsOffset = sliceOffset + symoff
        let stringsOffset = sliceOffset + stroff
        guard stringsOffset + strsize <= data.count else {
            return [:]
        }

        var symbols: [String: UInt64] = [:]
        for index in 0..<nsyms {
            let entryOffset = symbolsOffset + (index * 16)
            guard entryOffset + 16 <= data.count else { break }
            let stringIndex = Int(data.readUInt32LE(at: entryOffset))
            let value = data.readUInt64LE(at: entryOffset + 8)
            guard stringIndex > 0, stringIndex < strsize else { continue }
            let nameOffset = stringsOffset + stringIndex
            let name = data.readCString(at: nameOffset)
            if !name.isEmpty {
                symbols[name] = value
            }
        }
        return symbols
    }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        withUnsafeBytes { rawBuffer in
            rawBuffer.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        withUnsafeBytes { rawBuffer in
            rawBuffer.load(fromByteOffset: offset, as: UInt64.self).littleEndian
        }
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        withUnsafeBytes { rawBuffer in
            rawBuffer.load(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        withUnsafeBytes { rawBuffer in
            rawBuffer.load(fromByteOffset: offset, as: UInt64.self).bigEndian
        }
    }

    func readCString(at offset: Int) -> String {
        var cursor = offset
        while cursor < count, self[cursor] != 0 {
            cursor += 1
        }
        guard cursor > offset else { return "" }
        return String(decoding: self[offset..<cursor], as: UTF8.self)
    }
}

enum MobileDeviceTransportError: Error, CustomStringConvertible {
    case missingSymbol(String)
    case deviceNotFound(String)
    case transferFailed(String)

    var description: String {
        switch self {
        case let .missingSymbol(name):
            return "MobileDevice symbol unavailable: \(name)"
        case let .deviceNotFound(message):
            return message
        case let .transferFailed(message):
            return message
        }
    }
}

private final class MobileDeviceObject {
    let object: AnyObject

    init(_ object: AnyObject) {
        self.object = object
    }
}

enum MobileDeviceRamdiskTransport {
    typealias RecoveryCreateFn = @convention(c) (io_service_t) -> Unmanaged<AnyObject>?
    typealias RecoveryECIDFn = @convention(c) (AnyObject) -> UInt64
    typealias RecoverySendFileFn = @convention(c) (AnyObject, CFString) -> Int32
    typealias RecoverySendCommandFn = @convention(c) (AnyObject, CFString) -> Int32

    typealias USBCreateFn = @convention(c) (io_service_t) -> Unmanaged<AnyObject>?
    typealias DFUCreateFn = @convention(c) (CFAllocator?, AnyObject, UnsafeMutableRawPointer?) -> Unmanaged<AnyObject>?
    typealias DFUECIDFn = @convention(c) (AnyObject) -> UInt64
    typealias DFUDownloadFn = @convention(c) (AnyObject, CFString, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32

    static let dfuServiceName = "Apple Mobile Device (DFU Mode)"
    static let recoveryServiceName = "Apple Mobile Device (Recovery Mode)"

    static func sendDFUFile(path: String, ecid: UInt64?) throws {
        let usbDevice = try findDFUUSBDevice(ecid: ecid)
        let download: DFUDownloadFn = try requireLocalSymbol("_AMRPerformDFUFileDownload")
        let status = download(usbDevice.object, path as CFString, nil, nil)
        guard status == 0 else {
            throw MobileDeviceTransportError.transferFailed("DFU download failed for \(path) with code \(status)")
        }
    }

    static func sendRecoveryFile(path: String, ecid: UInt64?) throws {
        let recoveryDevice = try findRecoveryDevice(ecid: ecid)
        let send: RecoverySendFileFn = try requireExportedSymbol("_AMRecoveryModeDeviceSendFileToDevice")
        let status = send(recoveryDevice.object, path as CFString)
        guard status == 0 else {
            throw MobileDeviceTransportError.transferFailed("Recovery file transfer failed for \(path) with code \(status)")
        }
    }

    static func sendRecoveryCommand(_ command: String, ecid: UInt64?) throws {
        let recoveryDevice = try findRecoveryDevice(ecid: ecid)
        let send: RecoverySendCommandFn = try requireExportedSymbol("_AMRecoveryModeDeviceSendCommandToDevice")
        let status = send(recoveryDevice.object, command as CFString)
        guard status == 0 else {
            throw MobileDeviceTransportError.transferFailed("Recovery command '\(command)' failed with code \(status)")
        }
    }

    static func waitForRecovery(ecid: UInt64?, timeout: TimeInterval = 20) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let _ = try? findRecoveryDevice(ecid: ecid) {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw MobileDeviceTransportError.deviceNotFound("Timed out waiting for recovery mode device")
    }

    private static func findRecoveryDevice(ecid: UInt64?) throws -> MobileDeviceObject {
        let create: RecoveryCreateFn = try requireExportedSymbol("_AMRecoveryModeDeviceCreateWithIOService")
        let getECID: RecoveryECIDFn = try requireExportedSymbol("_AMRecoveryModeDeviceGetECID")

        return try findDevice(
            serviceName: recoveryServiceName,
            creator: { service in
                guard let device = create(service)?.takeRetainedValue() else { return nil }
                if let ecid, getECID(device) != ecid {
                    return nil
                }
                return MobileDeviceObject(device)
            },
            failureLabel: ecid.map { "No recovery mode device matched ECID 0x\(String($0, radix: 16).uppercased())" }
        )
    }

    private static func findDFUUSBDevice(ecid: UInt64?) throws -> MobileDeviceObject {
        let createUSB: USBCreateFn = try requireLocalSymbol("__AMRUSBDeviceCreateDevice")
        let createDFU: DFUCreateFn = try requireLocalSymbol("__AMDFUModeDeviceCreate")
        let getECID: DFUECIDFn = try requireExportedSymbol("_AMDFUModeDeviceGetECID")

        return try findDevice(
            serviceName: dfuServiceName,
            creator: { service in
                guard let usbDevice = createUSB(service)?.takeRetainedValue() else { return nil }
                guard let dfuDevice = createDFU(kCFAllocatorDefault, usbDevice, nil)?.takeRetainedValue() else {
                    return MobileDeviceObject(usbDevice)
                }
                if let ecid, getECID(dfuDevice) != ecid {
                    return nil
                }
                return MobileDeviceObject(usbDevice)
            },
            failureLabel: ecid.map { "No DFU mode device matched ECID 0x\(String($0, radix: 16).uppercased())" }
        )
    }

    private static func findDevice(serviceName: String, creator: (io_service_t) -> MobileDeviceObject?, failureLabel: String?) throws -> MobileDeviceObject {
        guard let matching = IOServiceNameMatching(serviceName) else {
            throw MobileDeviceTransportError.deviceNotFound("Failed to create IOService match dictionary for \(serviceName)")
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            throw MobileDeviceTransportError.deviceNotFound("IOService lookup failed for \(serviceName): \(result)")
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let device = creator(service) {
                return device
            }
        }

        throw MobileDeviceTransportError.deviceNotFound(failureLabel ?? "No \(serviceName) device found")
    }

    static func requireExportedSymbol<T>(_ name: String) throws -> T {
        guard let symbol: T = MobileDeviceImage.exported(name) else {
            throw MobileDeviceTransportError.missingSymbol(name)
        }
        return symbol
    }

    static func requireLocalSymbol<T>(_ name: String) throws -> T {
        guard let symbol: T = MobileDeviceImage.local(name) else {
            throw MobileDeviceTransportError.missingSymbol(name)
        }
        return symbol
    }
}
