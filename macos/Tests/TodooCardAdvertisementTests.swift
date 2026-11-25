import XCTest

@testable import TodooCardMacApp

/// TodooCard 广播解析与能力位派生测试。
final class TodooCardAdvertisementTests: XCTestCase {
    /// 构造 7 字节厂商广播：[ID0, ID1, Screen0, Flags, FW, Reserved, Screen1]
    private func makeData(
        manufacturer: UInt16 = 0x5053,
        screen: UInt16 = 0x134C,
        flags: UInt8 = 0,
        firmware: UInt8 = 0x9D
    ) -> Data {
        var data = Data()
        data.append(UInt8(truncatingIfNeeded: manufacturer))
        data.append(UInt8(truncatingIfNeeded: manufacturer >> 8))
        data.append(UInt8(truncatingIfNeeded: screen))
        data.append(flags)
        data.append(firmware)
        data.append(0)
        data.append(UInt8(truncatingIfNeeded: screen >> 8))
        return data
    }

    func testParseValidAdvertisement() throws {
        let advertisement = try XCTUnwrap(TodooCardAdvertisement(data: makeData(
            flags: 0x11,
            firmware: 0x9D
        )))
        XCTAssertEqual(advertisement.manufacturerID, 0x5053)
        XCTAssertEqual(advertisement.screenType, 0x134C)
        XCTAssertEqual(advertisement.capabilityFlags, 0x11)
        XCTAssertEqual(advertisement.firmwareVersion, 0x9D)
        XCTAssertTrue(advertisement.isTodooCard)
    }

    func testParseRejectsMissingOrShortData() {
        XCTAssertNil(TodooCardAdvertisement(data: nil))
        XCTAssertNil(TodooCardAdvertisement(data: Data()))
        XCTAssertNil(TodooCardAdvertisement(data: Data(repeating: 0, count: 6)))
    }

    func testIdentityMismatch() throws {
        let wrongManufacturer = try XCTUnwrap(TodooCardAdvertisement(data: makeData(manufacturer: 0x1234)))
        XCTAssertFalse(wrongManufacturer.isTodooCard)

        let wrongScreen = try XCTUnwrap(TodooCardAdvertisement(data: makeData(screen: 0x5678)))
        XCTAssertFalse(wrongScreen.isTodooCard)
    }

    func testSecureRequiresFirmwareAndFlag() throws {
        // 低固件 + 加密位：不算安全设备
        let oldFirmware = try XCTUnwrap(TodooCardAdvertisement(data: makeData(flags: 0x01, firmware: 0x8B)))
        XCTAssertFalse(oldFirmware.requiresEncryptedGatt)

        // 达标固件 + 加密位：安全设备，配对窗口未开
        let secure = try XCTUnwrap(TodooCardAdvertisement(data: makeData(flags: 0x01, firmware: 0x8C)))
        XCTAssertTrue(secure.requiresEncryptedGatt)
        XCTAssertFalse(secure.pairingWindowOpen)

        // 加密 + 0x02 位：配对窗口开启
        let pairing = try XCTUnwrap(TodooCardAdvertisement(data: makeData(flags: 0x03, firmware: 0x8C)))
        XCTAssertTrue(pairing.pairingWindowOpen)
    }

    func testRecoveryAndTurboFlags() throws {
        let recovery = try XCTUnwrap(TodooCardAdvertisement(data: makeData(flags: 0x08)))
        XCTAssertTrue(recovery.otaRecoveryMode)
        XCTAssertFalse(recovery.turboLink)

        let turbo = try XCTUnwrap(TodooCardAdvertisement(data: makeData(flags: 0x10)))
        XCTAssertTrue(turbo.turboLink)
        XCTAssertFalse(turbo.otaRecoveryMode)
    }

    func testVerifiedTransferAndDiagnosticsThresholds() throws {
        let below = try XCTUnwrap(TodooCardAdvertisement(data: makeData(firmware: 0x9C)))
        XCTAssertFalse(below.usesVerifiedTransfer)
        XCTAssertFalse(below.supportsAckDiagnostics)

        let verified = try XCTUnwrap(TodooCardAdvertisement(data: makeData(firmware: 0x9D)))
        XCTAssertTrue(verified.usesVerifiedTransfer)
        XCTAssertFalse(verified.supportsAckDiagnostics)

        let diagnostics = try XCTUnwrap(TodooCardAdvertisement(data: makeData(firmware: 0xA5)))
        XCTAssertTrue(diagnostics.supportsAckDiagnostics)
    }
}
