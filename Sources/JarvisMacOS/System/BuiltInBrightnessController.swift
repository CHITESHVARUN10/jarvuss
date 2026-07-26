import Foundation
import CoreGraphics
import IOKit
import IOKit.graphics

// MARK: - BuiltInBrightnessController

/// Controls the brightness of the MacBook built-in display using a
/// fallback chain of private/semi-private macOS APIs.
///
/// Built-in displays are NOT accessible via DDC/CI (no external cable).
/// This controller uses runtime dlopen/dlsym so a missing symbol
/// causes graceful fallback rather than a crash.
///
/// Fallback chain (highest confidence first):
///   1. DisplayServices.framework — DisplayServicesSetBrightness / GetBrightness
///      (works on Apple Silicon, macOS 11+, preferred path)
///   2. CoreDisplay.framework — CoreDisplay_Display_SetUserBrightness
///      (works on Intel, does NOT work on Apple Silicon per brightness.c comments)
///   3. IOKit IODisplaySetFloatParameter (deprecated since 10.9, last resort)
///
/// ⚠️  API Stability: DisplayServices and CoreDisplay are private frameworks.
///    They have survived across macOS 12–15 but could change without notice.
///    The dlopen approach ensures a symbol missing → fallback, not crash.
final class BuiltInBrightnessController {

    var onLog: ((String) -> Void)?

    // MARK: - Function pointer typedefs (matching C signatures)

    private typealias CanChangeBrightnessFn  = @convention(c) (UInt32) -> Bool
    private typealias GetBrightnessFn        = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn        = @convention(c) (UInt32, Float) -> Int32
    private typealias BrightnessChangedFn    = @convention(c) (UInt32, Double) -> Void
    private typealias CDGetBrightnessFn      = @convention(c) (UInt32) -> Double
    private typealias CDSetBrightnessFn      = @convention(c) (UInt32, Double) -> Void

    // MARK: - Lazily resolved symbols

    private lazy var displayServicesHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    }()

    private lazy var coreDisplayHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
    }()

    private lazy var fnCanChange: CanChangeBrightnessFn? = {
        resolve(displayServicesHandle, "DisplayServicesCanChangeBrightness")
    }()

    private lazy var fnGetBrightness: GetBrightnessFn? = {
        resolve(displayServicesHandle, "DisplayServicesGetBrightness")
    }()

    private lazy var fnSetBrightness: SetBrightnessFn? = {
        resolve(displayServicesHandle, "DisplayServicesSetBrightness")
    }()

    private lazy var fnBrightnessChanged: BrightnessChangedFn? = {
        resolve(displayServicesHandle, "DisplayServicesBrightnessChanged")
    }()

    private lazy var fnCDGetBrightness: CDGetBrightnessFn? = {
        resolve(coreDisplayHandle, "CoreDisplay_Display_GetUserBrightness")
    }()

    private lazy var fnCDSetBrightness: CDSetBrightnessFn? = {
        resolve(coreDisplayHandle, "CoreDisplay_Display_SetUserBrightness")
    }()

    // MARK: - Public API

    /// Returns true if the built-in display supports brightness adjustment.
    func canChangeBrightness() -> Bool {
        guard let displayID = builtInDisplayID() else { return false }
        if let fn = fnCanChange { return fn(displayID) }
        // If symbol missing, optimistically return true and let set attempt fail gracefully.
        return fnSetBrightness != nil || fnCDSetBrightness != nil
    }

    /// Returns current brightness in 0.0–1.0 range, or nil if unavailable.
    func getBrightness() -> Float? {
        guard let displayID = builtInDisplayID() else {
            emit("[Brightness] No built-in display found")
            return nil
        }

        // Path 1: DisplayServicesGetBrightness (Apple Silicon preferred)
        if let fn = fnGetBrightness {
            var value: Float = 0
            let result = fn(displayID, &value)
            if result == 0 {
                emit("[Brightness] DisplayServicesGetBrightness = \(value)")
                return value
            }
            emit("[Brightness] DisplayServicesGetBrightness failed (\(result)), trying CoreDisplay")
        }

        // Path 2: CoreDisplay (Intel)
        if let fn = fnCDGetBrightness {
            let value = Float(fn(displayID))
            emit("[Brightness] CoreDisplay_Display_GetUserBrightness = \(value)")
            return value
        }

        emit("[Brightness] No brightness read method available")
        return nil
    }

    /// Sets brightness in 0.0–1.0 range.
    /// Returns true if any method successfully applied the change.
    @discardableResult
    func setBrightness(_ level: Float) -> Bool {
        let clamped = min(max(level, 0.0), 1.0)
        guard let displayID = builtInDisplayID() else {
            emit("[Brightness] No built-in display found")
            return false
        }

        emit("[Brightness] Setting brightness to \(Int(clamped * 100))%")

        // Path 1: DisplayServicesSetBrightness (macOS 11+, Apple Silicon)
        if let fn = fnSetBrightness {
            let result = fn(displayID, clamped)
            if result == 0 {
                // Notify system UI so slider in Control Center updates.
                fnBrightnessChanged?(displayID, Double(clamped))
                emit("[Brightness] DisplayServicesSetBrightness: OK")
                return true
            }
            emit("[Brightness] DisplayServicesSetBrightness failed (\(result)), trying CoreDisplay")
        }

        // Path 2: CoreDisplay (Intel Macs, does NOT work on Apple Silicon)
        if let fn = fnCDSetBrightness {
            fn(displayID, Double(clamped))
            emit("[Brightness] CoreDisplay_Display_SetUserBrightness: applied (no return code)")
            // Notify system UI.
            fnBrightnessChanged?(displayID, Double(clamped))
            return true
        }

        // Path 3: IOKit IODisplaySetFloatParameter (deprecated, last resort)
        if setViaIOKit(displayID: displayID, brightness: clamped) {
            emit("[Brightness] IODisplaySetFloatParameter: OK")
            return true
        }

        emit("[Brightness][ERROR] All brightness methods failed")
        return false
    }

    /// Increase brightness by a delta (0.0–1.0 scale).
    @discardableResult
    func increaseBrightness(by delta: Float) -> Bool {
        let current = getBrightness() ?? 0.5
        return setBrightness(current + delta)
    }

    /// Decrease brightness by a delta.
    @discardableResult
    func decreaseBrightness(by delta: Float) -> Bool {
        let current = getBrightness() ?? 0.5
        return setBrightness(current - delta)
    }

    // MARK: - IOKit fallback (deprecated path)

    private func setViaIOKit(displayID: CGDirectDisplayID, brightness: Float) -> Bool {
        // Manually match IOService for the display (CGDisplayIOServicePort deprecated in 10.9).
        let vendor = CGDisplayVendorNumber(displayID)
        let model  = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)

        var ioIterator: io_iterator_t = 0
        let matchDict = IOServiceMatching("IODisplayConnect") as NSMutableDictionary
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &ioIterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(ioIterator) }

        var entry = IOIteratorNext(ioIterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(ioIterator) }
            // Match by vendor/model/serial from IODisplayEDID properties.
            let props = IODisplayCreateInfoDictionary(entry, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: AnyObject]
            let v = props?[kDisplayVendorID as String] as? UInt32 ?? 0
            let m = props?[kDisplayProductID as String] as? UInt32 ?? 0
            let s = props?[kDisplaySerialNumber as String] as? UInt32 ?? 0
            guard v == vendor, m == model, s == serial else { continue }

            let key = kIODisplayBrightnessKey as CFString
            var val = brightness
            let result = IODisplaySetFloatParameter(entry, 0, key, val)
            return result == kIOReturnSuccess
        }
        return false
    }

    // MARK: - Display discovery

    /// Returns the CGDirectDisplayID of the first built-in display, or nil.
    func builtInDisplayID() -> CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &displays, &count)
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    // MARK: - Helpers

    private func resolve<T>(_ handle: UnsafeMutableRawPointer?, _ symbol: String) -> T? {
        guard let handle, let ptr = dlsym(handle, symbol) else {
            emit("[Brightness] Symbol '\(symbol)' not found")
            return nil
        }
        return unsafeBitCast(ptr, to: T.self)
    }

    private func emit(_ message: String) {
        onLog?(message) ?? { print(message) }()
    }
}
