import Foundation

/// TodooCard 广播数据的共享解析模型。
///
/// 设备扫描与传输服务共用同一份厂商字段解析与能力位派生，避免多处解析逻辑漂移。
/// 广播结构：`manufacturerID / screenType / capabilityFlags / firmwareVersion`（7 字节）。
struct TodooCardAdvertisement: Equatable {
    static let expectedManufacturerID: UInt16 = 0x5053
    static let expectedScreenType: UInt16 = 0x134C

    let manufacturerID: UInt16
    let screenType: UInt16
    let capabilityFlags: UInt8
    let firmwareVersion: UInt8

    init?(data: Data?) {
        guard let data, data.count >= 7 else { return nil }
        self.manufacturerID = UInt16(data[0]) | UInt16(data[1]) << 8
        self.screenType = UInt16(data[2]) | UInt16(data[6]) << 8
        self.capabilityFlags = data[3]
        self.firmwareVersion = data[4]
    }

    var isTodooCard: Bool {
        manufacturerID == Self.expectedManufacturerID && screenType == Self.expectedScreenType
    }

    /// 固件 v140+ 且声明加密 GATT：需要先完成系统配对。
    var requiresEncryptedGatt: Bool {
        screenType == Self.expectedScreenType &&
            firmwareVersion >= 0x8C &&
            (capabilityFlags & 0x01) != 0
    }

    /// 新机配对窗口开启（此期间拒绝传图）。
    var pairingWindowOpen: Bool {
        requiresEncryptedGatt && (capabilityFlags & 0x02) != 0
    }

    /// OTA 恢复模式（拒绝传图）。
    var otaRecoveryMode: Bool {
        (capabilityFlags & 0x08) != 0
    }

    /// Turbo 链路。
    var turboLink: Bool {
        (capabilityFlags & 0x10) != 0
    }

    /// v157+ 固件支持 32 块校验窗口的可靠传输。
    var usesVerifiedTransfer: Bool {
        firmwareVersion >= 0x9D
    }

    /// v165+ 固件失败后可读取保留的 image-ACK 诊断特征。
    var supportsAckDiagnostics: Bool {
        firmwareVersion >= 0xA5
    }
}
