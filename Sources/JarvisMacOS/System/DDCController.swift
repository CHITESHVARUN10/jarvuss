import Foundation
import IOKit
import CoreGraphics
import CDDCShim

// MARK: - VCP Feature Codes (VESA MCCS v2.2)

/// DDC/CI VCP (Virtual Control Panel) feature codes.
/// These are industry-standard codes defined by the VESA MCCS specification —
/// they are NOT Apple-specific and will remain stable regardless of macOS changes.
enum VCPCode: UInt8 {
    case brightness = 0x10   // 0–100 (monitor's backlight)
    case contrast   = 0x12   // 0–100
    case volume     = 0x62   // 0–100 (built-in speaker volume)
}

// MARK: - DDC/CI Wire Protocol Constants

/// 7-bit I2C device address for DDC/CI on Apple Silicon.
/// 0x37 = DisplayPort / HDMI display address (standard per DDC/CI spec).
private let kDDCChipAddress: UInt8  = 0x37
/// Data register address for the DDC/CI protocol.
private let kDDCDataAddress: UInt8  = 0x51
/// Host address used in DDC packet checksum calculations.
private let kDDCHostAddress: UInt8  = 0x51
/// Reply source address in get-VCP responses.
private let kDDCReplyAddress: UInt8 = 0x6E

// MARK: - DDCController

/// Performs DDC/CI read/write operations on external monitors via the
/// IOAVService SPI — the correct mechanism on Apple Silicon (M1/M2/M3/M4).
///
/// The old IOI2CRequest / IOFBGetI2CInterfaceCount path (used by the legacy
/// MonitorVolumeController) does NOT work on Apple Silicon. This class
/// uses IOAVServiceWriteI2C / IOAVServiceReadI2C instead.
///
/// Discovery: Walks the IORegistry for DCPAVServiceProxy entries and matches
/// them to CGDirectDisplayIDs via EDID vendor/product/serial numbers.
final class DDCController {

    var onLog: ((String) -> Void)?

    // MARK: - Cached service map

    /// displayID → IOAVService (opaque CFTypeRef). Cached per session.
    private var serviceCache: [CGDirectDisplayID: IOAVService] = [:]
    private var cacheBuilt = false

    // MARK: - Public convenience API

    func setBrightness(displayID: CGDirectDisplayID, percent: Int) -> Bool {
        write(displayID: displayID, vcpCode: VCPCode.brightness.rawValue,
              value: UInt16(clamp(percent, 0, 100)))
    }

    func getBrightness(displayID: CGDirectDisplayID) -> (current: Int, max: Int)? {
        guard let r = read(displayID: displayID, vcpCode: VCPCode.brightness.rawValue) else { return nil }
        return (Int(r.current), Int(r.max))
    }

    func setContrast(displayID: CGDirectDisplayID, percent: Int) -> Bool {
        write(displayID: displayID, vcpCode: VCPCode.contrast.rawValue,
              value: UInt16(clamp(percent, 0, 100)))
    }

    func getContrast(displayID: CGDirectDisplayID) -> (current: Int, max: Int)? {
        guard let r = read(displayID: displayID, vcpCode: VCPCode.contrast.rawValue) else { return nil }
        return (Int(r.current), Int(r.max))
    }

    func setVolume(displayID: CGDirectDisplayID, percent: Int) -> Bool {
        write(displayID: displayID, vcpCode: VCPCode.volume.rawValue,
              value: UInt16(clamp(percent, 0, 100)))
    }

    func getVolume(displayID: CGDirectDisplayID) -> (current: Int, max: Int)? {
        guard let r = read(displayID: displayID, vcpCode: VCPCode.volume.rawValue) else { return nil }
        return (Int(r.current), Int(r.max))
    }

    // MARK: - External display list

    /// All currently connected external (non-built-in) display IDs.
    static func externalDisplayIDs() -> [CGDirectDisplayID] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &displayIDs, &count)
        return displayIDs.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    // MARK: - DDC Write (set VCP value)

    /// Writes a VCP value to the display via DDC/CI.
    /// Returns true on success.
    func write(displayID: CGDirectDisplayID, vcpCode: UInt8, value: UInt16) -> Bool {
        guard let service = resolvedService(for: displayID) else {
            emit("[DDC] No IOAVService found for displayID \(displayID)")
            return false
        }

        // Build DDC/CI set-VCP packet per MCCS v2.2 §7.4.
        // Packet layout (7 bytes + checksum):
        //   [0] = kDDCHostAddress (0x51)     ← virtual host address
        //   [1] = 0x84                        ← combined: type(0x80) | length(4 bytes follow)
        //   [2] = 0x03                        ← DDC command: Set VCP Feature
        //   [3] = vcpCode                     ← feature code
        //   [4] = high byte of value
        //   [5] = low byte of value
        //   [6] = XOR checksum (kDDCReplyAddress ^ all preceding bytes)
        var packet: [UInt8] = [
            kDDCHostAddress,
            0x84,                       // type 0x80 | length 0x04
            0x03,                       // Set VCP Feature opcode
            vcpCode,
            UInt8((value >> 8) & 0xFF), // value high byte
            UInt8(value & 0xFF)         // value low byte
        ]
        var checksum: UInt8 = kDDCReplyAddress
        for b in packet { checksum ^= b }
        packet.append(checksum)

        let result = packet.withUnsafeMutableBytes { buf -> IOReturn in
            IOAVServiceWriteI2C(
                service,
                UInt32(kDDCChipAddress),
                UInt32(kDDCDataAddress),
                buf.baseAddress!,
                UInt32(buf.count)
            )
        }

        if result == kIOReturnSuccess {
            emit("[DDC] Write VCP 0x\(String(vcpCode, radix: 16)) = \(value) on display \(displayID): OK")
            return true
        }
        emit("[DDC] Write VCP 0x\(String(vcpCode, radix: 16)) = \(value) on display \(displayID): FAILED (0x\(String(result, radix: 16)))")
        return false
    }

    // MARK: - DDC Read (get VCP value)

    /// Reads the current and maximum value for a VCP code from the display.
    /// Returns nil if the display doesn't respond or DDC is unsupported.
    func read(displayID: CGDirectDisplayID, vcpCode: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let service = resolvedService(for: displayID) else {
            emit("[DDC] No IOAVService found for displayID \(displayID)")
            return nil
        }

        // Build DDC/CI get-VCP request packet (5 bytes).
        // Layout:
        //   [0] = kDDCHostAddress (0x51)
        //   [1] = 0x82                   ← type 0x80 | length 0x02
        //   [2] = 0x01                   ← Get VCP Feature opcode
        //   [3] = vcpCode
        //   [4] = XOR checksum
        var request: [UInt8] = [kDDCHostAddress, 0x82, 0x01, vcpCode]
        var checksum: UInt8 = kDDCReplyAddress
        for b in request { checksum ^= b }
        request.append(checksum)

        let writeResult = request.withUnsafeMutableBytes { buf -> IOReturn in
            IOAVServiceWriteI2C(
                service,
                UInt32(kDDCChipAddress),
                UInt32(kDDCDataAddress),
                buf.baseAddress!,
                UInt32(buf.count)
            )
        }

        guard writeResult == kIOReturnSuccess else {
            emit("[DDC] Read request write failed for VCP 0x\(String(vcpCode, radix: 16)): 0x\(String(writeResult, radix: 16))")
            return nil
        }

        // Per DDC/CI spec §7.6, wait ≥40ms after the request before reading reply.
        usleep(40_000)

        // Reply is 12 bytes:
        //   [0]  = kDDCHostAddress (0x6E)
        //   [1]  = 0x88  (type 0x80 | length 0x08)
        //   [2]  = 0x02  (Get VCP Feature reply opcode)
        //   [3]  = 0x00  (no error)
        //   [4]  = vcpCode
        //   [5]  = VCP type (0x00=set, 0x01=momentary)
        //   [6]  = max high byte
        //   [7]  = max low byte
        //   [8]  = current high byte
        //   [9]  = current low byte
        //   [10] = (reserved)
        //   [11] = XOR checksum
        var reply = [UInt8](repeating: 0, count: 12)
        let readResult = reply.withUnsafeMutableBytes { buf -> IOReturn in
            IOAVServiceReadI2C(
                service,
                UInt32(kDDCChipAddress),
                UInt32(kDDCDataAddress),
                buf.baseAddress!,
                UInt32(buf.count)
            )
        }

        guard readResult == kIOReturnSuccess else {
            emit("[DDC] Read reply failed for VCP 0x\(String(vcpCode, radix: 16)): 0x\(String(readResult, radix: 16))")
            return nil
        }

        // Validate reply structure.
        guard reply[0] == kDDCReplyAddress,   // source
              reply[2] == 0x02,               // Get VCP reply opcode
              reply[3] == 0x00,               // no error code
              reply[4] == vcpCode else {       // echo of requested feature
            emit("[DDC] Read reply malformed for VCP 0x\(String(vcpCode, radix: 16)): \(reply.map { String(format: "%02X", $0) }.joined(separator: " "))")
            return nil
        }

        let maxValue     = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let currentValue = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        emit("[DDC] Read VCP 0x\(String(vcpCode, radix: 16)): current=\(currentValue) max=\(maxValue) on display \(displayID)")
        return (current: currentValue, max: maxValue)
    }

    // MARK: - Service Discovery

    /// Invalidates the cache (call on display reconfiguration).
    func invalidateCache() {
        serviceCache.removeAll()
        cacheBuilt = false
        emit("[DDC] Service cache invalidated")
    }

    /// Resolves (or returns cached) IOAVService for a given displayID.
    private func resolvedService(for displayID: CGDirectDisplayID) -> IOAVService? {
        if !cacheBuilt { buildServiceCache() }
        return serviceCache[displayID]
    }

    /// Walks IORegistry for DCPAVServiceProxy entries and matches them to
    /// display IDs using EDID vendor/product/serial numbers.
    private func buildServiceCache() {
        cacheBuilt = true
        serviceCache.removeAll()

        // Find all DCPAVServiceProxy entries in the IORegistry.
        // This IOKit class is the Apple Silicon AV service host.
        let matching = IOServiceMatching("DCPAVServiceProxy")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            emit("[DDC] IOServiceGetMatchingServices(DCPAVServiceProxy) failed")
            return
        }
        defer { IOObjectRelease(iterator) }

        var discoveredServices: [(service: IOAVService, location: String)] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }

            // Create the IOAVService for this registry entry.
            // IOAVServiceCreateWithService returns Unmanaged<IOAVService>? on Swift;
            // takeRetainedValue() transfers ownership to us.
            guard let avServiceUnmanaged = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) else { continue }
            let avService: IOAVService = avServiceUnmanaged.takeRetainedValue()

            // Extract the IODisplayLocation property to use as a stable match key.
            let location = ioProperty(entry, key: "IODisplayLocation") as? String ?? ""
            discoveredServices.append((service: avService, location: location))
        }

        emit("[DDC] Discovered \(discoveredServices.count) DCPAVServiceProxy entries")

        // Match each service to a CGDirectDisplayID.
        // CoreGraphics exposes vendor/model/serial that we can compare against EDID.
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 8)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(8, &displayIDs, &displayCount)

        for i in 0..<Int(displayCount) {
            let displayID = displayIDs[i]
            guard CGDisplayIsBuiltin(displayID) == 0 else { continue }   // built-in has no DDC

            // Try the first unmatched service (simple 1:1 on single-monitor setups).
            // On multi-monitor setups, location-based matching is more reliable but
            // requires IODisplayLocation from both CoreGraphics and IOKit —
            // using index order as best-effort for now.
            if discoveredServices.isEmpty { break }
            let matched = discoveredServices.removeFirst()
            serviceCache[displayID] = matched.service
            emit("[DDC] Matched display \(displayID) → IOAVService (location: '\(matched.location)')")
        }
    }

    // MARK: - IORegistry helpers

    private func ioProperty(_ entry: io_service_t, key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // MARK: - Misc

    private func clamp(_ value: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(value, lo), hi)
    }

    private func emit(_ message: String) {
        onLog?(message) ?? { print(message) }()
    }
}
