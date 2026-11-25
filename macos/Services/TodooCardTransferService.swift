import CoreBluetooth
import Foundation
import os

/// TodooCard BLE 图片传输服务。
///
/// 以 `raw/TodooCard_Skills-main` 中的 `mac_image_transfer.swift` 为参考实现移植：
/// 负责广播校验、安全链路验证、控制命令握手、分块数据传输（新固件 32 块校验窗口）、
/// 刷新确认与失败诊断。payload 始终使用 raw 控制器格式（flags 0x03），兼容全部固件版本。
@MainActor
final class TodooCardTransferService: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case connecting
        case verifying
        case negotiating
        case transferring
        case waitingRefresh
        case succeeded
        case failed
        case cancelled

        var isTerminal: Bool {
            self == .succeeded || self == .failed || self == .cancelled
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusText = "未开始传输"
    @Published private(set) var progress: Double = 0
    @Published private(set) var bytesSent = 0
    @Published private(set) var bytesTotal = 0
    @Published private(set) var lastError: String?
    @Published private(set) var diagnosticsText: String?

    var isTransferActive: Bool {
        switch phase {
        case .scanning, .connecting, .verifying, .negotiating, .transferring, .waitingRefresh:
            return true
        default:
            return false
        }
    }

    // MARK: - 协议模型
    // 广播解析与能力位派生使用共享模型 `TodooCardAdvertisement`（Models/）。

    private enum Command: UInt8 {
        case requestBlockSize = 1
        case requestScreenSize = 2
        case requestStartTransfer = 3
        case dataAck = 5
    }

    private enum Status: UInt8 {
        case success = 0
        case transferEnd = 8
    }

    private struct ImageAckDiagnostics {
        let session: UInt8
        let flags: UInt8
        let generatedCount: UInt16
        let notifyAttemptCount: UInt16
        let notifyAcceptedCount: UInt16
        let notifyRejectedCount: UInt16
        let requestedBlock: UInt32
        let previousBlockStatus: UInt8
        let lastNotifyResult: UInt8
        let lastReceivedBlock: UInt16

        static func parse(_ data: Data) -> ImageAckDiagnostics? {
            guard data.count >= 20, data[0] == 0x27, data[1] == 0x01 else { return nil }
            func uint16(_ offset: Int) -> UInt16 {
                UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
            }
            let requested = UInt32(data[12])
                | UInt32(data[13]) << 8
                | UInt32(data[14]) << 16
                | UInt32(data[15]) << 24
            return ImageAckDiagnostics(
                session: data[2],
                flags: data[3],
                generatedCount: uint16(4),
                notifyAttemptCount: uint16(6),
                notifyAcceptedCount: uint16(8),
                notifyRejectedCount: uint16(10),
                requestedBlock: requested,
                previousBlockStatus: data[16],
                lastNotifyResult: data[17],
                lastReceivedBlock: uint16(18)
            )
        }

        var descriptionText: String {
            func yesNo(_ flag: UInt8) -> String { flag != 0 ? "是" : "否" }
            return "会话=\(session) " +
                "活跃=\(yesNo(flags & 0x01)) " +
                "待写入=\(yesNo(flags & 0x02)) " +
                "已收块=\(yesNo(flags & 0x04)) " +
                "最近接受=\(yesNo(flags & 0x08)) " +
                "生成=\(generatedCount) 尝试=\(notifyAttemptCount) " +
                "接受=\(notifyAcceptedCount) 拒绝=\(notifyRejectedCount) " +
                "请求块=\(requestedBlock) " +
                "上一状态=0x\(String(previousBlockStatus, radix: 16)) " +
                "通知结果=0x\(String(lastNotifyResult, radix: 16)) " +
                "最近收块=\(lastReceivedBlock)"
        }
    }

    private static let imageServiceUUIDs = [
        CBUUID(string: "0000FEF0-0000-1000-8000-00805F9B34FB"),
        CBUUID(string: "0000FDF0-0000-1000-8000-00805F9B34FB")
    ]
    private static let controlCharacteristicUUIDs = [
        CBUUID(string: "0000FEF1-0000-1000-8000-00805F9B34FB"),
        CBUUID(string: "0000FDF1-0000-1000-8000-00805F9B34FB")
    ]
    private static let dataCharacteristicUUIDs = [
        CBUUID(string: "0000FEF2-0000-1000-8000-00805F9B34FB"),
        CBUUID(string: "0000FDF2-0000-1000-8000-00805F9B34FB")
    ]
    private static let batteryServiceUUID = CBUUID(string: "180F")
    private static let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")
    private static let diagnosticsServiceUUID = CBUUID(string: "D8B282F0-0F9B-4A7A-B5E8-8E6E5A3C1001")
    private static let imageAckDiagnosticsCharacteristicUUID = CBUUID(string: "D8B282F0-0F9B-4A7A-B5E8-8E6E5A3C1003")

    /// v157+ 校验窗口传输（每 32 块等待 durable checkpoint）。
    private static let verifiedTransferMinimumVersion: UInt8 = 0x9D
    /// v165+ 失败时可读取保留的 image-ACK 诊断特征。
    private static let imageAckDiagnosticsMinimumVersion: UInt8 = 0xA5
    private static let verifiedWindowBlocks = 32
    private static let checkpointTimeoutSeconds: TimeInterval = 5
    private static let verifiedFinalAckTimeoutSeconds: TimeInterval = 10
    private static let standardFinalAckTimeoutSeconds: TimeInterval = 5
    private static let maximumRepairRequests = 16
    private static let maximumConnectionAttempts = 3
    private static let connectTimeoutSeconds: TimeInterval = 15
    private static let prepareTimeoutSeconds: TimeInterval = 35
    private static let scanTimeoutSeconds: TimeInterval = 45

    // MARK: - BLE 会话状态

    private var centralManager: CBCentralManager!
    private var targetID: UUID?
    private var advertisedInfo: TodooCardAdvertisement?
    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var diagnosticsCharacteristic: CBCharacteristic?
    private var secureLinkVerified = false
    private var connectionAttempt = 0
    private var serviceDiscoveryCompleted = false
    private var notificationSettled = false
    private var notificationSettleScheduled = false
    private var transferStarted = false

    private let logger = Logger(subsystem: "com.todoo.TodooCardMacApp", category: "transfer")

    // MARK: - 传输状态

    private var payload = Data()
    private var usesVerifiedWindows = false
    private var blockPayloadSize = 0
    private var nextVerifiedBlockIndex: Int?
    private var verifiedWindowStart = 0
    private var verifiedWindowEnd = 0
    private var lastSentBlockIndex = -1
    private var repairRequestCount = 0
    private var completePayloadWritten = false
    private var finalTransferAckReceived = false
    private var verifiedWriteResponsePending = false
    private var earlyVerifiedRequestedBlock: Int?
    private var diagnosticReadPending = false
    private var lastControlCommand: UInt8?
    private var retriedControlWithoutResponse = false

    // MARK: - 超时定时器

    private var scanTimer: Timer?
    private var connectTimer: Timer?
    private var prepareTimer: Timer?
    private var discoveryRetryTimers: [Timer] = []
    private var settleTimer: Timer?
    private var batteryRefreshTimer: Timer?
    private var checkpointAckTimer: Timer?
    private var finalAckTimer: Timer?
    private var controlResponseTimer: Timer?
    private var controlFallbackTimer: Timer?
    private var failureDiagnosticsTimer: Timer?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    // 定时器均为一次性且回调捕获 [weak self]，无需在 deinit 中逐一失效：
    // 实例释放后回调自动空转，运行循环最迟在触发点后释放定时器。

    // MARK: - 公开接口

    func startTransfer(controllerPayload: Data, deviceID: UUID) {
        guard !isTransferActive else { return }
        guard !controllerPayload.isEmpty else {
            phase = .failed
            statusText = "传输失败"
            lastError = "传输数据为空"
            return
        }

        resetSession()
        payload = controllerPayload
        targetID = deviceID
        bytesTotal = controllerPayload.count
        bytesSent = 0
        progress = 0
        lastError = nil
        diagnosticsText = nil
        phase = .scanning
        statusText = "正在扫描目标设备"
        logger.info(
            "开始传输：payload=\(controllerPayload.count) 字节 设备=\(deviceID.uuidString, privacy: .public)"
        )

        if centralManager.state == .poweredOn {
            beginScan()
        } else {
            // 蓝牙未就绪（权限弹窗未决/初始化中）：didUpdateState 可能迟迟不来，
            // 安排超时兜底并把具体状态暴露给用户，避免无限等待。
            statusText = "等待蓝牙就绪"
            scanTimer?.invalidate()
            scanTimer = scheduleTimeout(10) { [weak self] in
                guard let self, self.phase == .scanning else { return }
                if let message = bluetoothUnavailableMessage(for: self.centralManager.state) {
                    self.failTransfer(message)
                } else {
                    self.failTransfer(
                        "蓝牙初始化超时（状态码 \(self.centralManager.state.rawValue)），请检查系统蓝牙开关与隐私权限设置"
                    )
                }
            }
        }
    }

    func cancel() {
        guard isTransferActive else { return }
        cancelAllTimers()
        centralManager.stopScan()
        if let peripheral, peripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        phase = .cancelled
        statusText = "传输已取消"
    }

    // MARK: - 会话与定时器管理

    private func resetSession() {
        cancelAllTimers()
        centralManager.stopScan()
        if let peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        controlCharacteristic = nil
        dataCharacteristic = nil
        batteryCharacteristic = nil
        diagnosticsCharacteristic = nil
        secureLinkVerified = false
        connectionAttempt = 0
        serviceDiscoveryCompleted = false
        notificationSettled = false
        notificationSettleScheduled = false
        transferStarted = false
        blockPayloadSize = 0
        usesVerifiedWindows = false
        lastControlCommand = nil
        retriedControlWithoutResponse = false
        resetTransferState()
    }

    private func resetTransferState() {
        nextVerifiedBlockIndex = nil
        verifiedWindowStart = 0
        verifiedWindowEnd = 0
        lastSentBlockIndex = -1
        repairRequestCount = 0
        completePayloadWritten = false
        finalTransferAckReceived = false
        verifiedWriteResponsePending = false
        earlyVerifiedRequestedBlock = nil
        diagnosticReadPending = false
    }

    private func cancelAllTimers() {
        [scanTimer, connectTimer, prepareTimer, settleTimer, batteryRefreshTimer,
         checkpointAckTimer, finalAckTimer, controlResponseTimer, controlFallbackTimer,
         failureDiagnosticsTimer].forEach { $0?.invalidate() }
        discoveryRetryTimers.forEach { $0.invalidate() }
        discoveryRetryTimers = []
    }

    private func scheduleTimeout(_ seconds: TimeInterval, handler: @escaping @MainActor () -> Void) -> Timer {
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard self != nil else { return }
                handler()
            }
        }
    }

    private func bluetoothUnavailableMessage(for state: CBManagerState) -> String? {
        switch state {
        case .poweredOff:
            return "蓝牙已关闭，请先开启蓝牙"
        case .unauthorized:
            return "没有蓝牙权限，请在系统设置中授权"
        case .unsupported:
            return "此 Mac 不支持蓝牙"
        case .resetting:
            return "蓝牙正在重置"
        default:
            return nil
        }
    }

    // MARK: - 扫描与连接

    private func beginScan() {
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        scanTimer?.invalidate()
        scanTimer = scheduleTimeout(Self.scanTimeoutSeconds) { [weak self] in
            guard let self, self.phase == .scanning else { return }
            self.failTransfer("扫描超时：未找到目标 TodooCard 设备")
        }
    }

    private func connect(_ target: CBPeripheral) {
        connectionAttempt += 1
        statusText = "正在连接设备（第 \(connectionAttempt)/\(Self.maximumConnectionAttempts) 次）"
        centralManager.connect(target, options: nil)
        connectTimer?.invalidate()
        connectTimer = scheduleTimeout(Self.connectTimeoutSeconds) { [weak self, weak target] in
            guard let self, let target,
                  self.peripheral === target,
                  target.state != .connected,
                  self.isTransferActive else { return }
            self.failTransfer("连接设备超时（第 \(self.connectionAttempt) 次尝试）")
        }
    }

    /// 加密链路建立超时（CBErrorDomain code 15）时，对同一设备重试连接。
    private func retryEncryptionTimeout(_ target: CBPeripheral, error: Error?) -> Bool {
        let systemError = error as NSError?
        guard advertisedInfo?.requiresEncryptedGatt == true,
              !secureLinkVerified,
              systemError?.domain == "CBErrorDomain",
              systemError?.code == 15,
              connectionAttempt < Self.maximumConnectionAttempts,
              isTransferActive else { return false }

        let delay = connectionAttempt == 1 ? 0.75 : 1.5
        controlCharacteristic = nil
        dataCharacteristic = nil
        batteryCharacteristic = nil
        diagnosticsCharacteristic = nil
        statusText = "加密链路超时，\(delay)s 后重试"
        connectTimer?.invalidate()
        connectTimer = scheduleTimeout(delay) { [weak self, weak target] in
            guard let self, let target,
                  self.peripheral === target,
                  target.state == .disconnected,
                  self.isTransferActive else { return }
            self.connect(target)
        }
        return true
    }

    // MARK: - GATT 握手

    private func beginIfReady() {
        guard peripheral != nil,
              controlCharacteristic != nil,
              dataCharacteristic != nil,
              isTransferActive else { return }
        guard advertisedInfo?.requiresEncryptedGatt != true || secureLinkVerified else { return }
        guard !transferStarted else { return }
        let waitsForNotification = controlCharacteristic?.properties.contains(.notify) == true ||
            controlCharacteristic?.properties.contains(.indicate) == true
        guard !waitsForNotification || (controlCharacteristic?.isNotifying == true && notificationSettled) else { return }

        transferStarted = true
        phase = .negotiating
        statusText = "正在协商传输参数"
        writeCommand(Data([Command.requestBlockSize.rawValue]))
    }

    private func writeCommand(_ data: Data) {
        guard let peripheral, let controlCharacteristic else { return }
        // withResponse 提供确定的 ATT 结果；若链路阻塞，超时后自动回退 withoutResponse 重试。
        let writeType: CBCharacteristicWriteType = controlCharacteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        lastControlCommand = data.first
        retriedControlWithoutResponse = false
        armControlResponseTimer(command: data.first, originalData: data, writeType: writeType)
        armControlFallbackTimer(command: data.first, originalData: data)
        peripheral.writeValue(data, for: controlCharacteristic, type: writeType)
    }

    private func armControlResponseTimer(command: UInt8?, originalData: Data, writeType: CBCharacteristicWriteType) {
        controlResponseTimer?.invalidate()
        controlResponseTimer = nil
        guard command != nil else { return }
        controlResponseTimer = scheduleTimeout(5) { [weak self] in
            guard let self else { return }
            if writeType == .withResponse,
               !self.retriedControlWithoutResponse,
               let peripheral = self.peripheral,
               let characteristic = self.controlCharacteristic,
               characteristic.properties.contains(.writeWithoutResponse) {
                self.retriedControlWithoutResponse = true
                peripheral.writeValue(originalData, for: characteristic, type: .withoutResponse)
                self.armControlResponseTimer(command: command, originalData: originalData, writeType: .withoutResponse)
                return
            }
            self.failTransfer("控制命令响应超时")
        }
    }

    private func armControlFallbackTimer(command: UInt8?, originalData: Data) {
        controlFallbackTimer?.invalidate()
        controlFallbackTimer = nil
        guard let command,
              let characteristic = controlCharacteristic,
              characteristic.properties.contains(.writeWithoutResponse) else { return }
        controlFallbackTimer = scheduleTimeout(0.6) { [weak self] in
            guard let self,
                  self.lastControlCommand == command,
                  self.controlResponseTimer != nil,
                  !self.retriedControlWithoutResponse,
                  let peripheral = self.peripheral,
                  let characteristic = self.controlCharacteristic else { return }
            self.retriedControlWithoutResponse = true
            peripheral.writeValue(originalData, for: characteristic, type: .withoutResponse)
        }
    }

    // MARK: - 控制通道

    private func handleControlMessage(_ data: Data) {
        let bytes = [UInt8](data)
        guard let command = Command(rawValue: bytes.first ?? 0) else { return }

        controlResponseTimer?.invalidate()
        controlResponseTimer = nil
        controlFallbackTimer?.invalidate()
        controlFallbackTimer = nil
        retriedControlWithoutResponse = false
        lastControlCommand = nil

        switch command {
        case .requestBlockSize:
            guard bytes.count >= 3, bytes[2] == Status.success.rawValue else {
                failTransfer("设备拒绝了数据块大小请求")
                return
            }
            blockPayloadSize = max(0, Int(bytes[1]) - 4)
            guard blockPayloadSize > 0 else {
                failTransfer("设备返回的数据块大小无效：\(bytes.count >= 2 ? bytes[1] : 0)")
                return
            }
            logger.info("握手：数据块大小 \(self.blockPayloadSize) 字节")
            requestScreenSize()
        case .requestScreenSize:
            guard bytes.count >= 2, bytes[1] == Status.success.rawValue else {
                failTransfer("设备拒绝了 payload 长度")
                return
            }
            phase = .transferring
            writeCommand(Data([Command.requestStartTransfer.rawValue]))
        case .requestStartTransfer:
            break
        case .dataAck:
            handleDataAck(bytes)
        }
    }

    private func handleDataAck(_ bytes: [UInt8]) {
        guard bytes.count >= 2 else { return }
        if bytes[1] == Status.transferEnd.rawValue {
            if usesVerifiedWindows, !completePayloadWritten {
                // 刷新确认先于本地队列收尾到达：暂存，待队列完成后结算。
                finalTransferAckReceived = true
                return
            }
            finishSuccessfulTransfer()
            return
        }
        guard bytes[1] == Status.success.rawValue else {
            failTransfer(transferErrorMessage(status: bytes[1]))
            return
        }
        guard bytes.count >= 6 else {
            failTransfer("设备返回了格式错误的数据确认")
            return
        }
        let index = Int(bytes[2]) | Int(bytes[3]) << 8 | Int(bytes[4]) << 16 | Int(bytes[5]) << 24
        if usesVerifiedWindows {
            checkpointAckTimer?.invalidate()
            checkpointAckTimer = nil
            if nextVerifiedBlockIndex != nil || verifiedWriteResponsePending {
                earlyVerifiedRequestedBlock = index
                return
            }
            beginVerifiedWindow(at: index)
        } else {
            sendStandardBlock(index)
        }
    }

    private func requestScreenSize() {
        var data = Data([Command.requestScreenSize.rawValue])
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { buffer in
            data.append(contentsOf: buffer)
        }
        data.append(0x03)
        writeCommand(data)
    }

    // MARK: - 数据传输

    private var totalBlockCount: Int {
        guard blockPayloadSize > 0 else { return 0 }
        return (payload.count + blockPayloadSize - 1) / blockPayloadSize
    }

    private func makeBlock(index: Int) -> (packet: Data, written: Int, isLast: Bool)? {
        guard blockPayloadSize > 0 else { return nil }
        let offset = index * blockPayloadSize
        guard offset >= 0, offset < payload.count else { return nil }
        let length = min(blockPayloadSize, payload.count - offset)
        var packet = Data()
        var blockIndex = UInt32(index).littleEndian
        withUnsafeBytes(of: &blockIndex) { buffer in
            packet.append(contentsOf: buffer)
        }
        packet.append(payload.subdata(in: offset..<offset + length))
        let written = offset + length
        return (packet, written, written >= payload.count)
    }

    private func emitProgress(written: Int) {
        bytesSent = written
        progress = min(1, Double(written) / Double(max(payload.count, 1)))
        statusText = "传输中 \(Int(progress * 100))%"
    }

    /// 旧固件路径：逐块发送，设备按 ACK 推进。
    private func sendStandardBlock(_ index: Int) {
        guard let peripheral, let dataCharacteristic, isTransferActive,
              let block = makeBlock(index: index) else { return }
        let writeType: CBCharacteristicWriteType = dataCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        peripheral.writeValue(block.packet, for: dataCharacteristic, type: writeType)
        lastSentBlockIndex = max(lastSentBlockIndex, index)
        emitProgress(written: block.written)
        if block.isLast {
            completePayloadWritten = true
            phase = .waitingRefresh
            statusText = "等待设备刷新确认"
            waitForFinalAck(seconds: Self.standardFinalAckTimeoutSeconds)
        }
    }

    /// 新固件（v157+ 校验窗口）路径：进入 [index, windowEnd) 窗口。
    private func beginVerifiedWindow(at index: Int) {
        let totalBlocks = totalBlockCount
        guard index >= 0, index <= totalBlocks else {
            failTransfer("设备返回了无效的续传块 \(index)；总块数=\(totalBlocks)")
            return
        }
        if index == totalBlocks {
            guard completePayloadWritten || lastSentBlockIndex >= totalBlocks - 1 else {
                failTransfer("设备在块 \(index) 处跳过了剩余 payload 数据")
                return
            }
            completePayloadWritten = true
            phase = .waitingRefresh
            statusText = "设备已确认全部块，等待刷新确认"
            waitForFinalAck(seconds: Self.verifiedFinalAckTimeoutSeconds)
            return
        }

        if lastSentBlockIndex >= 0 {
            guard index <= verifiedWindowEnd else {
                failTransfer("设备确认从窗口尾 \(verifiedWindowEnd) 跳到了块 \(index)")
                return
            }
            if index < verifiedWindowEnd {
                repairRequestCount += 1
                guard repairRequestCount <= Self.maximumRepairRequests else {
                    failTransfer("设备要求的块修复次数过多（\(repairRequestCount)），请靠近设备后重试")
                    return
                }
                statusText = "修复未完成的窗口（第 \(repairRequestCount)/\(Self.maximumRepairRequests) 次）"
            } else {
                repairRequestCount = 0
                statusText = "设备已持久化确认至块 \(index)"
            }
        }

        finalAckTimer?.invalidate()
        finalAckTimer = nil
        completePayloadWritten = false
        verifiedWindowStart = index
        verifiedWindowEnd = min(((index / Self.verifiedWindowBlocks) + 1) * Self.verifiedWindowBlocks, totalBlocks)
        nextVerifiedBlockIndex = index
        earlyVerifiedRequestedBlock = nil
        logger.info(
            "校验窗口 [\(self.verifiedWindowStart), \(self.verifiedWindowEnd))，总块数 \(totalBlocks)，修复次数 \(self.repairRequestCount)"
        )
        pumpVerifiedWindow()
    }

    private func pumpVerifiedWindow() {
        guard usesVerifiedWindows,
              !verifiedWriteResponsePending,
              let peripheral,
              let dataCharacteristic,
              isTransferActive,
              var index = nextVerifiedBlockIndex else { return }

        let supportsNoResponse = dataCharacteristic.properties.contains(.writeWithoutResponse)
        let supportsResponse = dataCharacteristic.properties.contains(.write)
        guard supportsNoResponse || supportsResponse else {
            failTransfer("数据特征不支持任何写入模式")
            return
        }

        while index < verifiedWindowEnd {
            guard let block = makeBlock(index: index) else {
                failTransfer("无法构造数据块 \(index)")
                return
            }
            let isBarrier = index + 1 >= verifiedWindowEnd
            if supportsResponse && (isBarrier || !supportsNoResponse) {
                // 窗口尾块使用 withResponse 作为屏障，保证队列收尾时机确定。
                verifiedWriteResponsePending = true
                nextVerifiedBlockIndex = index + 1
                lastSentBlockIndex = max(lastSentBlockIndex, index)
                peripheral.writeValue(block.packet, for: dataCharacteristic, type: .withResponse)
                emitProgress(written: block.written)
                return
            }
            guard peripheral.canSendWriteWithoutResponse else {
                nextVerifiedBlockIndex = index
                return
            }
            peripheral.writeValue(block.packet, for: dataCharacteristic, type: .withoutResponse)
            lastSentBlockIndex = max(lastSentBlockIndex, index)
            emitProgress(written: block.written)
            index += 1
            nextVerifiedBlockIndex = index
        }
        finishQueuedVerifiedWindow()
    }

    private func finishQueuedVerifiedWindow() {
        guard nextVerifiedBlockIndex != nil, isTransferActive else { return }
        nextVerifiedBlockIndex = nil
        verifiedWriteResponsePending = false
        let isFinalWindow = verifiedWindowEnd >= totalBlockCount
        if isFinalWindow {
            completePayloadWritten = true
        }

        if finalTransferAckReceived, completePayloadWritten {
            finishSuccessfulTransfer()
            return
        }
        if let earlyRequestedBlock = earlyVerifiedRequestedBlock {
            earlyVerifiedRequestedBlock = nil
            beginVerifiedWindow(at: earlyRequestedBlock)
            return
        }
        if isFinalWindow {
            phase = .waitingRefresh
            statusText = "等待设备刷新确认"
            waitForFinalAck(seconds: Self.verifiedFinalAckTimeoutSeconds)
        } else {
            statusText = "等待设备持久化确认（窗口至块 \(verifiedWindowEnd)）"
            armCheckpointWait()
        }
    }

    /// 窗口队列收尾后等待 durable checkpoint；超时只重发窗口尾块探测进度。
    private func armCheckpointWait() {
        checkpointAckTimer?.invalidate()
        let expectedWindowStart = verifiedWindowStart
        let expectedWindowEnd = verifiedWindowEnd
        checkpointAckTimer = scheduleTimeout(Self.checkpointTimeoutSeconds) { [weak self] in
            guard let self,
                  self.nextVerifiedBlockIndex == nil,
                  self.verifiedWindowStart == expectedWindowStart,
                  self.verifiedWindowEnd == expectedWindowEnd,
                  self.isTransferActive else { return }
            guard self.repairRequestCount < Self.maximumRepairRequests else {
                self.failTransfer("等待设备持久化确认超时（已探测 \(Self.maximumRepairRequests) 次）")
                return
            }
            self.repairRequestCount += 1
            let probeIndex = max(expectedWindowEnd - 1, expectedWindowStart)
            guard let peripheral = self.peripheral,
                  let characteristic = self.dataCharacteristic,
                  let block = self.makeBlock(index: probeIndex) else {
                self.failTransfer("无法发送持久化确认探测块")
                return
            }
            let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write)
                ? .withResponse
                : .withoutResponse
            self.statusText =
                "持久化确认超时，探测窗口尾块（第 \(self.repairRequestCount)/\(Self.maximumRepairRequests) 次）"
            peripheral.writeValue(block.packet, for: characteristic, type: writeType)
            self.armCheckpointWait()
        }
    }

    private func waitForFinalAck(seconds: TimeInterval) {
        finalAckTimer?.invalidate()
        finalAckTimer = scheduleTimeout(seconds) { [weak self] in
            guard let self, self.isTransferActive else { return }
            self.failTransfer("等待设备刷新确认（0x05/0x08）超时")
        }
    }

    // MARK: - 结果处理

    private func finishSuccessfulTransfer() {
        cancelAllTimers()
        phase = .succeeded
        statusText = "传输成功，设备正在刷新画面"
        progress = 1
        bytesSent = payload.count
        logger.info("传输成功：\(self.payload.count) 字节已确认（0x05/0x08）")
        if let peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func transferErrorMessage(status: UInt8) -> String {
        switch status {
        case 0x01:
            return "设备拒绝了格式错误或乱序的数据块（0x01）"
        case 0x09:
            return "设备外部 Flash 写入失败（0x09）"
        case 0x0A:
            return "设备外部 Flash 回读校验失败（0x0A）"
        default:
            return String(format: "设备中断了图片传输（状态 0x%02X）", status)
        }
    }

    private func failTransfer(_ message: String) {
        guard isTransferActive else { return }
        cancelAllTimers()
        centralManager.stopScan()
        phase = .failed
        statusText = "传输失败"
        lastError = message
        logger.error("传输失败：\(message, privacy: .public)")

        // v165+ 固件会在失败后保留 image-ACK 诊断，读取后再断开。
        if (advertisedInfo?.firmwareVersion ?? 0) >= Self.imageAckDiagnosticsMinimumVersion,
           let peripheral,
           peripheral.state == .connected,
           let diagnosticsCharacteristic,
           diagnosticsCharacteristic.properties.contains(.read) {
            diagnosticReadPending = true
            peripheral.readValue(for: diagnosticsCharacteristic)
            failureDiagnosticsTimer?.invalidate()
            failureDiagnosticsTimer = scheduleTimeout(1.8) { [weak self] in
                self?.finishPendingFailureIfNeeded(force: true)
            }
            return
        }
        finishPendingFailureIfNeeded(force: true)
    }

    private func finishPendingFailureIfNeeded(force: Bool = false) {
        guard force || !diagnosticReadPending else { return }
        diagnosticReadPending = false
        failureDiagnosticsTimer?.invalidate()
        failureDiagnosticsTimer = nil
        if let peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension TodooCardTransferService: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isTransferActive, peripheral == nil else { return }
        if central.state == .poweredOn {
            if phase == .scanning {
                beginScan()
            }
            return
        }
        if phase == .scanning, let message = bluetoothUnavailableMessage(for: central.state) {
            failTransfer(message)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard phase == .scanning, let targetID, peripheral.identifier == targetID else { return }

        let advertisement = TodooCardAdvertisement(
            data: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        )
        guard let advertisement else {
            failTransfer("目标设备的 TodooCard 广播数据缺失")
            return
        }
        guard advertisement.isTodooCard else {
            failTransfer("目标设备身份不匹配（厂商=0x\(String(advertisement.manufacturerID, radix: 16))）")
            return
        }
        guard !advertisement.pairingWindowOpen else {
            failTransfer("设备处于新机配对窗口，拒绝传图；请等待配对窗口关闭后重试")
            return
        }
        guard !advertisement.otaRecoveryMode else {
            failTransfer("设备处于 OTA 恢复模式，拒绝传图；请先修复固件")
            return
        }

        advertisedInfo = advertisement
        usesVerifiedWindows = advertisement.usesVerifiedTransfer

        central.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil
        self.peripheral = peripheral
        peripheral.delegate = self
        phase = .connecting
        logger.info(
            "发现目标设备：固件=v\(advertisement.firmwareVersion) secure=\(advertisement.requiresEncryptedGatt) 校验窗口=\(advertisement.usesVerifiedTransfer)"
        )
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimer?.invalidate()
        connectTimer = nil
        serviceDiscoveryCompleted = false
        notificationSettled = false
        notificationSettleScheduled = false
        statusText = "正在发现 GATT 服务"
        peripheral.discoverServices(nil)

        discoveryRetryTimers.forEach { $0.invalidate() }
        discoveryRetryTimers = [3.0, 8.0].map { delay in
            scheduleTimeout(delay) { [weak self, weak peripheral] in
                guard let self, let peripheral,
                      self.peripheral === peripheral,
                      peripheral.state == .connected,
                      !self.serviceDiscoveryCompleted,
                      self.isTransferActive else { return }
                peripheral.discoverServices(nil)
            }
        }
        prepareTimer?.invalidate()
        prepareTimer = scheduleTimeout(Self.prepareTimeoutSeconds) { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.peripheral === peripheral,
                  peripheral.state == .connected,
                  !self.transferStarted,
                  self.isTransferActive else { return }
            self.failTransfer("准备设备连接超时")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard isTransferActive else { return }
        if retryEncryptionTimeout(peripheral, error: error) { return }
        failTransfer(error?.localizedDescription ?? "连接设备失败")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard isTransferActive, self.peripheral === peripheral else { return }
        if retryEncryptionTimeout(peripheral, error: error) { return }
        cancelAllTimers()
        if advertisedInfo?.requiresEncryptedGatt == true, !secureLinkVerified {
            failTransfer("安全配对链路不可用；请先在设备配对窗口中完成配对")
            return
        }
        if transferStarted {
            failTransfer(completePayloadWritten
                ? "设备在写入完成后、刷新确认前断开；本次传输未确认成功"
                : "传输过程中设备断开连接")
        } else {
            failTransfer("设备连接中断")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension TodooCardTransferService: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isTransferActive else { return }
        if let error {
            failTransfer("发现服务失败：\(error.localizedDescription)")
            return
        }
        serviceDiscoveryCompleted = true
        guard let services = peripheral.services, !services.isEmpty else {
            failTransfer("未找到图片传输服务")
            return
        }
        let imageService = services.first { Self.imageServiceUUIDs.contains($0.uuid) }

        if advertisedInfo?.requiresEncryptedGatt == true, !secureLinkVerified {
            guard let batteryService = services.first(where: { $0.uuid == Self.batteryServiceUUID }) else {
                failTransfer("未找到加密 Battery 服务，无法验证安全链路")
                return
            }
            peripheral.discoverCharacteristics([Self.batteryLevelCharacteristicUUID], for: batteryService)
            return
        }

        guard let imageService else {
            failTransfer("未找到图片传输服务")
            return
        }
        peripheral.discoverCharacteristics(
            Self.controlCharacteristicUUIDs + Self.dataCharacteristicUUIDs,
            for: imageService
        )
        if (advertisedInfo?.firmwareVersion ?? 0) >= Self.imageAckDiagnosticsMinimumVersion,
           let diagnosticsService = services.first(where: { $0.uuid == Self.diagnosticsServiceUUID }) {
            peripheral.discoverCharacteristics(
                [Self.imageAckDiagnosticsCharacteristicUUID],
                for: diagnosticsService
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard isTransferActive else { return }
        if let error {
            failTransfer("发现特征失败（\(service.uuid.uuidString)）：\(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            if Self.controlCharacteristicUUIDs.contains(characteristic.uuid) {
                controlCharacteristic = characteristic
                if characteristic.properties.contains(.notify) ||
                    characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if Self.dataCharacteristicUUIDs.contains(characteristic.uuid) {
                dataCharacteristic = characteristic
            } else if characteristic.uuid == Self.batteryLevelCharacteristicUUID {
                batteryCharacteristic = characteristic
            } else if characteristic.uuid == Self.imageAckDiagnosticsCharacteristicUUID {
                diagnosticsCharacteristic = characteristic
            }
        }

        if service.uuid == Self.batteryServiceUUID {
            guard let batteryCharacteristic else {
                failTransfer("加密 Battery Level 特征缺失")
                return
            }
            phase = .verifying
            statusText = "正在验证安全链路"
            peripheral.readValue(for: batteryCharacteristic)
            return
        }
        beginIfReady()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isTransferActive else { return }
        if let error {
            failTransfer("开启控制通知失败：\(error.localizedDescription)")
            return
        }
        guard !notificationSettleScheduled else { return }
        notificationSettleScheduled = true
        settleTimer?.invalidate()
        settleTimer = scheduleTimeout(0.4) { [weak self] in
            guard let self, self.isTransferActive else { return }
            self.notificationSettled = true
            self.beginIfReady()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isTransferActive || diagnosticReadPending else { return }
        if characteristic.uuid == Self.imageAckDiagnosticsCharacteristicUUID {
            handleDiagnosticsValue(characteristic, error: error)
            return
        }
        if characteristic.uuid == Self.batteryLevelCharacteristicUUID {
            handleBatteryValue(peripheral, characteristic: characteristic, error: error)
            return
        }
        guard isTransferActive else { return }
        if let error {
            failTransfer("控制通知失败：\(error.localizedDescription)")
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
        guard isTransferActive else { return }
        if let error {
            failTransfer("写入 \(characteristic.uuid.uuidString) 失败：\(error.localizedDescription)")
            return
        }
        if Self.dataCharacteristicUUIDs.contains(characteristic.uuid),
           usesVerifiedWindows,
           verifiedWriteResponsePending {
            verifiedWriteResponsePending = false
            if let nextVerifiedBlockIndex, nextVerifiedBlockIndex < verifiedWindowEnd {
                pumpVerifiedWindow()
            } else {
                finishQueuedVerifiedWindow()
            }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard isTransferActive else { return }
        if usesVerifiedWindows {
            pumpVerifiedWindow()
        }
    }

    private func handleBatteryValue(
        _ peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            failTransfer("安全配对验证失败：\(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, data.count == 1 else {
            failTransfer("加密 Battery Level 返回了无效数据")
            return
        }
        secureLinkVerified = true
        statusText = "安全链路已验证（电量 \(data[0])%），正在重新发现服务"

        // 留出 1.8s 供 Service Changed 缓存刷新，然后重新发现传输服务。
        controlCharacteristic = nil
        dataCharacteristic = nil
        batteryCharacteristic = nil
        diagnosticsCharacteristic = nil
        notificationSettled = false
        notificationSettleScheduled = false
        serviceDiscoveryCompleted = false
        settleTimer?.invalidate()
        batteryRefreshTimer?.invalidate()
        batteryRefreshTimer = scheduleTimeout(1.8) { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.peripheral === peripheral,
                  peripheral.state == .connected,
                  self.isTransferActive else { return }
            peripheral.discoverServices(nil)
        }
    }

    private func handleDiagnosticsValue(_ characteristic: CBCharacteristic, error: Error?) {
        diagnosticReadPending = false
        if let error {
            diagnosticsText = "读取诊断失败：\(error.localizedDescription)"
        } else if let data = characteristic.value,
                  let diagnostics = ImageAckDiagnostics.parse(data) {
            diagnosticsText = diagnostics.descriptionText
        } else {
            diagnosticsText = "设备诊断数据无效"
        }
        finishPendingFailureIfNeeded()
    }
}
