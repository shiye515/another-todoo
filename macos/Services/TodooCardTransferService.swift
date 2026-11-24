import CoreBluetooth
import Foundation

@MainActor
final class TodooCardTransferService: NSObject, ObservableObject {
    @Published private(set) var statusText = "未开始传输"
    @Published private(set) var progress: Double = 0
    @Published private(set) var isTransferring = false
    @Published private(set) var lastError: String?

    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var targetID: UUID?
    private var payload = Data()
    private var blockPayloadSize = 0
    private var nextBlockIndex = 0
    private var firmwareVersion: UInt8 = 0
    private var transferTimer: Timer?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func transfer(controllerPayload: Data, to deviceID: UUID) {
        guard !controllerPayload.isEmpty else {
            lastError = "传输数据为空"
            return
        }
        guard centralManager.state == .poweredOn else {
            lastError = "蓝牙未就绪：\(centralManager.state)"
            return
        }

        targetID = deviceID
        payload = controllerPayload
        progress = 0
        lastError = nil
        isTransferring = true
        statusText = "正在扫描目标设备"
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        transferTimer?.invalidate()
        transferTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isTransferring else { return }
                self.stopWithError("扫描或连接设备超时")
            }
        }
    }

    func cancel() {
        transferTimer?.invalidate()
        transferTimer = nil
        if let peripheral = targetPeripheral,
           peripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        centralManager.stopScan()
        isTransferring = false
        statusText = "传输已取消"
    }

    private func stopWithError(_ message: String) {
        transferTimer?.invalidate()
        transferTimer = nil
        centralManager.stopScan()
        if let peripheral = targetPeripheral,
           peripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        isTransferring = false
        lastError = message
        statusText = "传输失败"
    }

    private func finishSuccess() {
        transferTimer?.invalidate()
        transferTimer = nil
        centralManager.stopScan()
        isTransferring = false
        progress = 1
        statusText = "传输成功"
    }

    private func writeControl(_ bytes: [UInt8]) {
        guard let peripheral = targetPeripheral,
              let characteristic = controlCharacteristic else { return }
        peripheral.writeValue(Data(bytes), for: characteristic, type: .withResponse)
    }

    private func startPayloadTransfer() {
        guard blockPayloadSize > 0 else {
            stopWithError("设备未返回有效数据块大小")
            return
        }

        var paddedPayload = payload
        let remainder = paddedPayload.count % blockPayloadSize
        if remainder != 0 {
            paddedPayload.append(Data(repeating: 0, count: blockPayloadSize - remainder))
        }
        payload = paddedPayload
        nextBlockIndex = 0
        pumpPayload()
    }

    private func pumpPayload() {
        guard let peripheral = targetPeripheral,
              let dataCharacteristic,
              blockPayloadSize > 0 else { return }

        while peripheral.canSendWriteWithoutResponse {
            let offset = nextBlockIndex * blockPayloadSize
            guard offset < payload.count else {
                statusText = "等待设备刷新确认"
                return
            }

            let length = min(blockPayloadSize, payload.count - offset)
            var packet = Data()
            packet.append(UInt32(nextBlockIndex).littleEndian.data)
            packet.append(payload.subdata(in: offset..<offset + length))

            peripheral.writeValue(packet, for: dataCharacteristic, type: .withoutResponse)
            nextBlockIndex += 1
            progress = min(1, Double(offset + length) / Double(payload.count))
            statusText = "传输中 \(Int(progress * 100))%"
        }
    }

    private func handleControlMessage(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }

        switch bytes[0] {
        case 0x01:
            guard bytes.count >= 3, bytes[2] == 0 else {
                stopWithError("设备拒绝数据块大小请求")
                return
            }
            blockPayloadSize = max(0, Int(bytes[1]) - 4)
            guard blockPayloadSize > 0 else {
                stopWithError("设备返回的数据块大小无效")
                return
            }

            var screenSize = Data([0x02])
            screenSize.append(UInt32(payload.count).littleEndian.data)
            screenSize.append(0x03)
            guard let peripheral = targetPeripheral,
                  let controlCharacteristic else { return }
            peripheral.writeValue(screenSize, for: controlCharacteristic, type: .withResponse)

        case 0x02:
            guard bytes.count >= 2, bytes[1] == 0 else {
                stopWithError("设备拒绝 payload 长度")
                return
            }
            writeControl([0x03])

        case 0x05:
            if bytes.count >= 2, bytes[1] == 0x08 {
                finishSuccess()
                return
            }
            if bytes.count >= 6 {
                let index = Int(UInt32(bytes[2]) |
                    (UInt32(bytes[3]) << 8) |
                    (UInt32(bytes[4]) << 16) |
                    (UInt32(bytes[5]) << 24))
                nextBlockIndex = max(0, index)
                statusText = "设备要求继续块 \(nextBlockIndex)"
                pumpPayload()
            } else if bytes.count >= 2 {
                stopWithError("设备传输状态异常：0x\(String(bytes[1], radix: 16))")
            }

        default:
            break
        }
    }
}

extension TodooCardTransferService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn,
           isTransferring,
           targetPeripheral == nil {
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let targetID, peripheral.identifier == targetID else { return }
        guard let manufacturerData =
            advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturerData.count >= 7 else { return }
        let manufacturerID = UInt16(manufacturerData[0]) |
            (UInt16(manufacturerData[1]) << 8)
        let screenType = UInt16(manufacturerData[2]) |
            (UInt16(manufacturerData[6]) << 8)
        firmwareVersion = manufacturerData[4]
        guard manufacturerID == 0x5053, screenType == 0x134C else { return }

        central.stopScan()
        targetPeripheral = peripheral
        peripheral.delegate = self
        statusText = "正在连接设备"
        central.connect(peripheral, options: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        statusText = "正在发现 GATT 服务"
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        stopWithError(error?.localizedDescription ?? "连接设备失败")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if isTransferring {
            stopWithError("设备传输中断开")
        }
    }
}

extension TodooCardTransferService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            stopWithError(error.localizedDescription)
            return
        }

        let imageServices: [CBUUID] = [
            CBUUID(string: "0000FEF0-0000-1000-8000-00805F9B34FB"),
            CBUUID(string: "0000FDF0-0000-1000-8000-00805F9B34FB")
        ]
        let batteryService = CBUUID(string: "180F")

        guard let services = peripheral.services else { return }
        if let service = services.first(where: { batteryService == $0.uuid }) {
            peripheral.discoverCharacteristics(
                [CBUUID(string: "2A19")],
                for: service
            )
        }

        guard let imageService = services.first(where: { imageServices.contains($0.uuid) }) else {
            stopWithError("未找到图片传输服务")
            return
        }
        peripheral.discoverCharacteristics(
            [
                CBUUID(string: "0000FEF1-0000-1000-8000-00805F9B34FB"),
                CBUUID(string: "0000FDF1-0000-1000-8000-00805F9B34FB"),
                CBUUID(string: "0000FEF2-0000-1000-8000-00805F9B34FB"),
                CBUUID(string: "0000FDF2-0000-1000-8000-00805F9B34FB")
            ],
            for: imageService
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            stopWithError(error.localizedDescription)
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid.uuidString == "2A19" {
                batteryCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
            } else if characteristic.uuid.uuidString.contains("FEF1") ||
                        characteristic.uuid.uuidString.contains("FDF1") {
                controlCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid.uuidString.contains("FEF2") ||
                        characteristic.uuid.uuidString.contains("FDF2") {
                dataCharacteristic = characteristic
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            stopWithError(error.localizedDescription)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            self?.writeControl([0x01])
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            stopWithError(error.localizedDescription)
            return
        }
        guard let data = characteristic.value else { return }
        handleControlMessage(data)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            stopWithError(error.localizedDescription)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpPayload()
    }
}

private extension UInt32 {
    var data: Data {
        var value = littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}
