import CoreBluetooth
import Foundation

@MainActor
final class DeviceScanner: NSObject, ObservableObject {
    @Published private(set) var bluetoothStateDescription = "初始化蓝牙"
    @Published private(set) var devices: [TodooCardDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanError: String?

    private var centralManager: CBCentralManager!
    private var scanTimer: Timer?
    private var startScanWhenReady = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan(duration: TimeInterval = 30) {
        scanError = nil
        scanTimer?.invalidate()

        guard centralManager.state == .poweredOn else {
            startScanWhenReady = true
            scanError = bluetoothStateDescription
            return
        }

        startScanWhenReady = false
        devices = []
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        scanTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopScan()
            }
        }
    }

    func stopScan() {
        startScanWhenReady = false
        scanTimer?.invalidate()
        scanTimer = nil
        if centralManager.isScanning {
            centralManager.stopScan()
        }
        isScanning = false
    }

    private func parseAdvertisement(_ data: Data?) -> (
        manufacturerID: UInt16?,
        screenType: UInt16?,
        firmwareVersion: UInt8?,
        capabilityFlags: UInt8?
    ) {
        guard let data, data.count >= 7 else {
            return (nil, nil, nil, nil)
        }
        let manufacturerID = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let screenType = UInt16(data[2]) | (UInt16(data[6]) << 8)
        return (
            manufacturerID,
            screenType,
            data[4],
            data[3]
        )
    }
}

extension DeviceScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown:
            bluetoothStateDescription = "正在初始化蓝牙"
        case .resetting:
            bluetoothStateDescription = "蓝牙正在重置"
        case .unsupported:
            bluetoothStateDescription = "此 Mac 不支持蓝牙"
        case .unauthorized:
            bluetoothStateDescription = "没有蓝牙权限，请在系统设置中授权"
        case .poweredOff:
            bluetoothStateDescription = "蓝牙已关闭，请先开启蓝牙"
        case .poweredOn:
            bluetoothStateDescription = "蓝牙已就绪"
        @unknown default:
            bluetoothStateDescription = "蓝牙状态未知"
        }

        if central.state != .poweredOn, isScanning {
            stopScan()
            scanError = bluetoothStateDescription
        }

        if central.state == .poweredOn, startScanWhenReady {
            startScan()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let parsed = parseAdvertisement(manufacturerData)
        let isTodooCard = parsed.manufacturerID == 0x5053 &&
            parsed.screenType == 0x134C

        guard isTodooCard else { return }

        let capabilityFlags = parsed.capabilityFlags
        let firmwareVersion = parsed.firmwareVersion
        let isSecure = parsed.screenType == 0x134C &&
            (firmwareVersion ?? 0) >= 0x8C &&
            ((capabilityFlags ?? 0) & 0x01) != 0
        let pairingWindowOpen = isSecure &&
            ((capabilityFlags ?? 0) & 0x02) != 0
        let otaRecoveryMode = ((capabilityFlags ?? 0) & 0x08) != 0
        let turboLink = ((capabilityFlags ?? 0) & 0x10) != 0
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = localName ?? peripheral.name ?? ""

        let device = TodooCardDevice(
            id: peripheral.identifier,
            name: name,
            manufacturerID: parsed.manufacturerID,
            screenType: parsed.screenType,
            firmwareVersion: firmwareVersion,
            capabilityFlags: capabilityFlags,
            rssi: RSSI.intValue,
            isTodooCard: isTodooCard,
            isSecure: isSecure,
            pairingWindowOpen: pairingWindowOpen,
            otaRecoveryMode: otaRecoveryMode,
            turboLink: turboLink,
            lastSeenAt: Date()
        )

        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        devices.sort { $0.rssi > $1.rssi }
    }
}
