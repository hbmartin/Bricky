import XCTest
@testable import Bricky

/// The floor is iPhone 17 Pro / Pro Max or a later Pro-class iPhone
/// (ADR 0012). The tables below are the device matrix the roadmap names.
final class DeviceFloorTests: XCTestCase {
    private func inputs(
        _ identifier: String,
        lidar: Bool = true,
        memoryGB: Double = 12,
        onMac: Bool = false
    ) -> DeviceFloor.Inputs {
        DeviceFloor.Inputs(
            hasLiDARAR: lidar,
            modelIdentifier: identifier,
            physicalMemoryBytes: UInt64(memoryGB * 1_000_000_000),
            isiOSAppOnMac: onMac
        )
    }

    func testSeventeenProAndProMaxAreSupported() {
        XCTAssertEqual(DeviceFloor.evaluate(inputs("iPhone18,1")), .supported)
        XCTAssertEqual(DeviceFloor.evaluate(inputs("iPhone18,2")), .supported)
    }

    func testLaterProModelsAreSupported() {
        XCTAssertEqual(DeviceFloor.evaluate(inputs("iPhone19,1", memoryGB: 16)), .supported)
    }

    func testSeventeenAndAirHaveNoLiDAR() {
        XCTAssertEqual(DeviceFloor.evaluate(inputs("iPhone18,3", lidar: false, memoryGB: 8)), .noLiDAR)
        XCTAssertEqual(DeviceFloor.evaluate(inputs("iPhone18,4", lidar: false)), .noLiDAR)
    }

    func testEarlierLiDARProsAreBelowTheFloor() {
        XCTAssertEqual(DeviceFloor.evaluate(inputs("iPhone17,1", memoryGB: 8)), .unsupportedModel("iPhone17,1"))
        XCTAssertEqual(DeviceFloor.evaluate(inputs("iPhone13,3", memoryGB: 6)), .unsupportedModel("iPhone13,3"))
    }

    func testLiDARiPadsAndUnknownIdentifiersAreRejected() {
        XCTAssertEqual(DeviceFloor.evaluate(inputs("iPad16,3", memoryGB: 16)), .unsupportedModel("iPad16,3"))
        XCTAssertEqual(DeviceFloor.evaluate(inputs("arm64")), .unsupportedModel("arm64"))
        XCTAssertEqual(DeviceFloor.evaluate(inputs("iPhone18")), .unsupportedModel("iPhone18"))
    }

    func testMemoryBelowTheFloorIsRejectedEvenOnANewIdentifier() {
        XCTAssertEqual(DeviceFloor.evaluate(inputs("iPhone19,5", memoryGB: 8)), .insufficientMemory(8_000_000_000))
    }

    func testMacIsRejectedFirst() {
        XCTAssertEqual(DeviceFloor.evaluate(inputs("Mac16,6", onMac: true)), .macNotSupported)
    }

    func testFamilyParsing() {
        XCTAssertEqual(DeviceFloor.iPhoneFamily("iPhone18,2"), 18)
        XCTAssertNil(DeviceFloor.iPhoneFamily("iPhone18,"))
        XCTAssertNil(DeviceFloor.iPhoneFamily("iPhoneX,1"))
        XCTAssertNil(DeviceFloor.iPhoneFamily("replay:iPhone18,1"))
    }
}
