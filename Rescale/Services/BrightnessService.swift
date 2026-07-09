import Foundation
import CoreGraphics
import IOKit

#if arch(arm64)

/// DDC/CI brightness control for external displays via IOAVServiceRef (Apple Silicon).
final class BrightnessService: @unchecked Sendable {
    static let shared = BrightnessService()

    private let lock = NSLock()
    private var serviceCache: [CGDirectDisplayID: IOAVServiceRef] = [:]
    private var maxCache: [CGDirectDisplayID: Double] = [:]

    private init() {}

    /// Reads current brightness (0–100) via DDC VCP code 0x10.
    func readBrightness(for displayID: CGDirectDisplayID) -> (current: Double, max: Double)? {
        guard let service = findService(for: displayID) else { return nil }
        guard let result = ddcRead(service: service, vcp: 0x10) else { return nil }

        lock.lock()
        maxCache[displayID] = result.max
        lock.unlock()

        return (current: (result.current / result.max) * 100.0, max: result.max)
    }

    /// Sets brightness (0–100) via DDC VCP code 0x10.
    func setBrightness(_ percent: Double, for displayID: CGDirectDisplayID) {
        guard let service = findService(for: displayID) else { return }

        // Get max value — use cache if available, otherwise read from display
        let maxVal: Double
        lock.lock()
        if let cached = maxCache[displayID] {
            maxVal = cached
            lock.unlock()
        } else {
            lock.unlock()
            guard let reading = ddcRead(service: service, vcp: 0x10) else { return }
            maxVal = reading.max
            lock.lock()
            maxCache[displayID] = maxVal
            lock.unlock()
        }

        let raw = UInt16(max(0, min(maxVal, percent / 100.0 * maxVal)))
        ddcWrite(service: service, vcp: 0x10, value: raw)
    }

    /// Clears cached state for a disconnected display.
    func clearCache(for displayID: CGDirectDisplayID) {
        lock.lock()
        serviceCache.removeValue(forKey: displayID)
        maxCache.removeValue(forKey: displayID)
        lock.unlock()
    }

    // MARK: - IOAVServiceRef Discovery

    /// Finds a working IOAVServiceRef for the given external display.
    private func findService(for displayID: CGDirectDisplayID) -> IOAVServiceRef? {
        lock.lock()
        if let cached = serviceCache[displayID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Enumerate all DCPAVServiceProxy nodes in the IOKit registry
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var working: [IOAVServiceRef] = []
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }

            // Skip built-in display entries
            if let loc = IORegistryEntryCreateCFProperty(
                entry, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String, loc != "External" { continue }

            guard let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) else { continue }

            // Verify this service responds to I2C
            var probe = [UInt8](repeating: 0, count: 32)
            if IOAVServiceReadI2C(avService, 0x37, 0x51, &probe, 32) == kIOReturnSuccess {
                working.append(avService)
            }
        }

        guard let service = working.first else { return nil }
        lock.lock()
        serviceCache[displayID] = service
        lock.unlock()
        return service
    }

    // MARK: - DDC I2C Protocol

    /// Sends a VCP Get request and parses the reply. Returns raw (current, max) values.
    private func ddcRead(service: IOAVServiceRef, vcp: UInt8) -> (current: Double, max: Double)? {
        // Build VCP Get request: [length|type, dataLength, vcpCode, checksum]
        var checksum = UInt8(0x6E ^ 0x51)
        let payload: [UInt8] = [0x82, 0x01, vcp]
        for b in payload { checksum ^= b }
        var request = payload + [checksum]

        guard IOAVServiceWriteI2C(service, 0x37, 0x51, &request, UInt32(request.count)) == kIOReturnSuccess else {
            return nil
        }

        // DDC/CI spec: 40ms reply delay
        Thread.sleep(forTimeInterval: 0.04)

        // Read VCP reply (12 bytes: header + max(hi,lo) + cur(hi,lo) + checksum)
        var reply = [UInt8](repeating: 0, count: 12)
        guard IOAVServiceReadI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
              reply.count >= 10 else { return nil }

        let maxVal = Double((UInt16(reply[6]) << 8) | UInt16(reply[7]))
        let curVal = Double((UInt16(reply[8]) << 8) | UInt16(reply[9]))
        guard maxVal > 0 else { return nil }

        return (current: curVal, max: maxVal)
    }

    /// Sends a VCP Set command.
    private func ddcWrite(service: IOAVServiceRef, vcp: UInt8, value: UInt16) {
        let hi = UInt8((value >> 8) & 0xFF)
        let lo = UInt8(value & 0xFF)
        var checksum = UInt8(0x6E ^ 0x51)
        let payload: [UInt8] = [0x84, 0x03, vcp, hi, lo]
        for b in payload { checksum ^= b }
        var buf = payload + [checksum]
        IOAVServiceWriteI2C(service, 0x37, 0x51, &buf, UInt32(buf.count))
    }
}

#else

/// Stub for Intel Macs — DDC via IOFramebuffer not implemented.
final class BrightnessService: @unchecked Sendable {
    static let shared = BrightnessService()
    private init() {}
    func readBrightness(for displayID: CGDirectDisplayID) -> (current: Double, max: Double)? { nil }
    func setBrightness(_ percent: Double, for displayID: CGDirectDisplayID) {}
    func clearCache(for displayID: CGDirectDisplayID) {}
}

#endif
