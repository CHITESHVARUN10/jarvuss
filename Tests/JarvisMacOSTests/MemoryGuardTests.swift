import XCTest
@testable import JarvisMacOS

/// Pure logic behind the memory watchdog — the part that decides WHEN to
/// terminate. The kernel reading itself is exercised in `testFootprintIsReadable`.
final class MemoryGuardTests: XCTestCase {

    private let gib: UInt64 = 1024 * 1024 * 1024

    func testDefaultLimitScalesWithPhysicalMemory() {
        XCTAssertEqual(MemoryGuard.defaultLimitGB(physicalMemoryBytes: 4 * gib), 2,
                       "small Macs clamp to the 2 GB floor")
        XCTAssertEqual(MemoryGuard.defaultLimitGB(physicalMemoryBytes: 8 * gib), 2)
        XCTAssertEqual(MemoryGuard.defaultLimitGB(physicalMemoryBytes: 16 * gib), 4)
        XCTAssertEqual(MemoryGuard.defaultLimitGB(physicalMemoryBytes: 24 * gib), 6)
        XCTAssertEqual(MemoryGuard.defaultLimitGB(physicalMemoryBytes: 64 * gib), 8,
                       "large Macs clamp to the 8 GB ceiling")
    }

    func testZeroOrNegativeMeansOff() {
        XCTAssertNil(MemoryGuard.limitBytes(forGB: 0))
        XCTAssertNil(MemoryGuard.limitBytes(forGB: -1))
        XCTAssertEqual(MemoryGuard.limitBytes(forGB: 6), 6 * gib)
    }

    func testEnvOverrideParsing() {
        XCTAssertEqual(MemoryGuard.limitBytes(envValue: "6"), 6 * gib)
        XCTAssertEqual(MemoryGuard.limitBytes(envValue: "0.25"), gib / 4,
                       "fractional values keep the kill path demonstrable")
        XCTAssertNil(MemoryGuard.limitBytes(envValue: "0"))
        XCTAssertNil(MemoryGuard.limitBytes(envValue: "off"))
    }

    func testThresholdIsInclusive() {
        let limit = MemoryGuard.limitBytes(forGB: 6)!
        XCTAssertFalse(MemoryGuard.shouldTerminate(footprintBytes: limit - 1, limitBytes: limit))
        XCTAssertTrue(MemoryGuard.shouldTerminate(footprintBytes: limit, limitBytes: limit),
                      "reaching the ceiling is the trigger — never overshoot it")
        XCTAssertTrue(MemoryGuard.shouldTerminate(footprintBytes: limit + 1, limitBytes: limit))
    }

    func testFootprintIsReadable() {
        XCTAssertGreaterThan(MemoryGuard.footprintBytes(), 0,
                             "task_vm_info must report a footprint on macOS")
    }
}
