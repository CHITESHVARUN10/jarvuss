import Foundation
import IOKit
import IOKit.i2c

final class MonitorVolumeController {
    var onLog: ((String) -> Void)?

    private(set) var currentPercent: Int = 50

    func setVolume(_ percent: Int) {
        _ = setVolumeResult(percent)
    }

    func increase(by delta: Int) {
        _ = setVolumeResult(currentPercent + delta)
    }

    func decrease(by delta: Int) {
        _ = setVolumeResult(currentPercent - delta)
    }

    @discardableResult
    func setVolumeResult(_ percent: Int) -> Bool {
        let safe = max(0, min(100, percent))
        emit("[DDC] Sending volume: \(safe)")

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        let matchStatus = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard matchStatus == KERN_SUCCESS else {
            emit("[DDC] Display found: false")
            emit("[DDC] Failure")
            return false
        }
        defer { IOObjectRelease(iterator) }

        var foundDisplay = false
        var wroteAtLeastOne = false

        while true {
            let displayService = IOIteratorNext(iterator)
            if displayService == 0 { break }
            foundDisplay = true
            defer { IOObjectRelease(displayService) }

            var busCount: IOItemCount = 0
            let countStatus = IOFBGetI2CInterfaceCount(displayService, &busCount)
            if countStatus != kIOReturnSuccess || busCount == 0 { continue }

            for busIndex in 0..<busCount {
                var interfaceService: io_service_t = 0
                let copyStatus = IOFBCopyI2CInterfaceForBus(displayService, IOOptionBits(busIndex), &interfaceService)
                if copyStatus != kIOReturnSuccess || interfaceService == 0 { continue }

                var connection: IOI2CConnectRef?
                let openStatus = IOI2CInterfaceOpen(interfaceService, IOOptionBits(0), &connection)
                guard openStatus == kIOReturnSuccess, let connection else {
                    IOObjectRelease(interfaceService)
                    continue
                }

                var request = IOI2CRequest()
                request.commFlags = 0
                request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                request.sendAddress = 0x6E
                request.sendSubAddress = 0
                request.replyAddress = 0
                request.replySubAddress = 0
                request.sendBytes = 0
                request.replyBytes = 0
                request.minReplyDelay = 0

                var packet = ddcSetVCPPacket(vcpCode: 0x62, value: UInt8(safe))
                let packetLength = UInt32(packet.count)
                let sendStatus: kern_return_t = packet.withUnsafeMutableBytes { bytes in
                    request.sendBuffer = vm_address_t(UInt(bitPattern: bytes.baseAddress))
                    request.sendBytes = packetLength
                    return IOI2CSendRequest(connection, IOOptionBits(0), &request)
                }

                let closeStatus = IOI2CInterfaceClose(connection, IOOptionBits(0))
                if closeStatus != kIOReturnSuccess {
                    emit("[DDC] Failure")
                }
                IOObjectRelease(interfaceService)

                if sendStatus == kIOReturnSuccess, request.result == kIOReturnSuccess {
                    wroteAtLeastOne = true
                }
            }
        }

        emit("[DDC] Display found: \(foundDisplay)")

        if wroteAtLeastOne {
            currentPercent = safe
            emit("[DDC] Success")
            return true
        }

        emit("[DDC] Failure")
        emit("[Volume][ERROR] Monitor does not support DDC volume")
        return false
    }

    private func ddcSetVCPPacket(vcpCode: UInt8, value: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x51, 0x82, 0x01, vcpCode, value]
        var checksum: UInt8 = 0x6E
        for byte in packet {
            checksum ^= byte
        }
        packet.append(checksum)
        return packet
    }

    private func emit(_ message: String) {
        if let onLog {
            onLog(message)
        } else {
            print(message)
        }
    }
}
