import CoreBluetooth
import Foundation
import os

@MainActor
final class DeviceScanner: NSObject, ObservableObject {
    /// 蓝牙状态枚举：UI 逻辑以此驱动，`description` 仅作展示。
    enum BluetoothState: Equatable {
        case initializing
        case resetting
        case unsupported
        case unauthorized
        case poweredOff
        case ready

        var description: String {
            switch self {
            case .initializing:
                return "正在初始化蓝牙"
            case .resetting:
                return "蓝牙正在重置"
            case .unsupported:
                return "此设备不支持蓝牙"
            case .unauthorized:
                return "没有蓝牙权限，请在系统设置中授权"
            case .poweredOff:
                return "蓝牙已关闭，请先开启蓝牙"
            case .ready:
                return "蓝牙已就绪"
            }
        }
    }

    @Published private(set) var bluetoothState: BluetoothState = .initializing
    var bluetoothStateDescription: String { bluetoothState.description }
    @Published private(set) var devices: [TodooCardDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanError: String?

    private let logger = Logger(subsystem: "com.todoo.TodooCardMacApp", category: "scanner")
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
        logger.info("开始扫描附近 BLE 设备")
        centralManager.scanForPeripherals(withServices: nil, options: nil)
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
}

extension DeviceScanner: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = Self.bluetoothState(for: central.state)

        if central.state != .poweredOn, isScanning {
            stopScan()
            scanError = bluetoothStateDescription
        }

        if central.state == .poweredOn, startScanWhenReady {
            startScan()
        }
    }

    private static func bluetoothState(for raw: CBManagerState) -> BluetoothState {
        switch raw {
        case .unknown:
            return .initializing
        case .resetting:
            return .resetting
        case .unsupported:
            return .unsupported
        case .unauthorized:
            return .unauthorized
        case .poweredOff:
            return .poweredOff
        case .poweredOn:
            return .ready
        @unknown default:
            return .initializing
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let advertisement = TodooCardAdvertisement(
            data: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        ), advertisement.isTodooCard else { return }

        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = localName ?? peripheral.name ?? ""

        let device = TodooCardDevice(
            id: peripheral.identifier,
            name: name,
            manufacturerID: advertisement.manufacturerID,
            screenType: advertisement.screenType,
            firmwareVersion: advertisement.firmwareVersion,
            capabilityFlags: advertisement.capabilityFlags,
            rssi: RSSI.intValue,
            isTodooCard: true,
            isSecure: advertisement.requiresEncryptedGatt,
            pairingWindowOpen: advertisement.pairingWindowOpen,
            otaRecoveryMode: advertisement.otaRecoveryMode,
            turboLink: advertisement.turboLink,
            lastSeenAt: Date()
        )

        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        devices.sort { $0.rssi > $1.rssi }
        logger.info(
            "发现 TodooCard：\(name.isEmpty ? peripheral.identifier.uuidString : name, privacy: .public) rssi=\(RSSI.intValue) 固件=v\(advertisement.firmwareVersion)"
        )
    }
}
