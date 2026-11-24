import Foundation

struct TodooCardDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let manufacturerID: UInt16?
    let screenType: UInt16?
    let firmwareVersion: UInt8?
    let capabilityFlags: UInt8?
    let rssi: Int
    let isTodooCard: Bool
    let isSecure: Bool
    let pairingWindowOpen: Bool
    let otaRecoveryMode: Bool
    let turboLink: Bool
    let lastSeenAt: Date

    var displayName: String {
        name.isEmpty ? "未命名设备" : name
    }

    var firmwareDescription: String {
        guard let firmwareVersion else { return "固件未知" }
        return "v\(firmwareVersion)（0x\(String(firmwareVersion, radix: 16, uppercase: true))）"
    }

    var statusDescription: String {
        if otaRecoveryMode { return "OTA 恢复模式" }
        if pairingWindowOpen { return "配对窗口已开启" }
        if isSecure { return "安全配对设备" }
        return "普通设备"
    }
}
