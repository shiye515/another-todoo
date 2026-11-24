import CoreBluetooth
import Foundation

private func log(_ message: String) {
    print(message)
    fflush(stdout)
}

private struct TodooAdvertisement {
    let manufacturerID: UInt16
    let screenType: UInt16
    let capabilityFlags: UInt8
    let firmwareVersion: UInt8

    var requiresEncryptedGatt: Bool {
        screenType == 0x134C && firmwareVersion >= 0x8C && (capabilityFlags & 0x01) != 0
    }

    var pairingWindowOpen: Bool {
        requiresEncryptedGatt && (capabilityFlags & 0x02) != 0
    }

    var otaRecoveryMode: Bool {
        (capabilityFlags & 0x08) != 0
    }

    var turboLink: Bool {
        (capabilityFlags & 0x10) != 0
    }

    var pairingHoldSeconds: Int {
        firmwareVersion >= 0x98 ? 5 : 10
    }
}

private func parseTodooAdvertisement(_ data: Data?) -> TodooAdvertisement? {
    guard let data, data.count >= 7 else { return nil }
    return TodooAdvertisement(
        manufacturerID: UInt16(data[0]) | UInt16(data[1]) << 8,
        screenType: UInt16(data[2]) | UInt16(data[6]) << 8,
        capabilityFlags: data[3],
        firmwareVersion: data[4]
    )
}

private func advertisementDescription(_ info: TodooAdvertisement?) -> String {
    guard let info else { return "manufacturer=unknown" }
    guard info.manufacturerID == 0x5053 else {
        return String(format: "manufacturer=0x%04X", info.manufacturerID)
    }
    return String(
        format: "manufacturer=0x%04X screen=0x%04X firmware=v%u(raw=0x%02X) flags=0x%02X secure=%@ pairing=%@ recovery=%@ turbo=%@",
        info.manufacturerID,
        info.screenType,
        info.firmwareVersion,
        info.firmwareVersion,
        info.capabilityFlags,
        info.requiresEncryptedGatt ? "yes" : "no",
        info.pairingWindowOpen ? "open" : "closed",
        info.otaRecoveryMode ? "yes" : "no",
        info.turboLink ? "yes" : "no"
    )
}

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

private enum Profile {
    case standard
    case compressed
}

private let serviceUUIDs = [
    CBUUID(string: "0000FEF0-0000-1000-8000-00805F9B34FB"),
    CBUUID(string: "0000FDF0-0000-1000-8000-00805F9B34FB")
]
private let controlCharacteristicUUIDs = [
    CBUUID(string: "0000FEF1-0000-1000-8000-00805F9B34FB"),
    CBUUID(string: "0000FDF1-0000-1000-8000-00805F9B34FB")
]
private let dataCharacteristicUUIDs = [
    CBUUID(string: "0000FEF2-0000-1000-8000-00805F9B34FB"),
    CBUUID(string: "0000FDF2-0000-1000-8000-00805F9B34FB")
]
private let batteryServiceUUID = CBUUID(string: "180F")
private let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")
private let diagnosticsServiceUUID = CBUUID(string: "D8B282F0-0F9B-4A7A-B5E8-8E6E5A3C1001")
private let imageAckDiagnosticsCharacteristicUUID = CBUUID(string: "D8B282F0-0F9B-4A7A-B5E8-8E6E5A3C1003")
private let verifiedTransferMinimumVersion: UInt8 = 0x9D
private let imageAckDiagnosticsMinimumVersion: UInt8 = 0xA5
private let verifiedWindowBlocks = 32
private let verifiedCheckpointTimeoutSeconds = 5
private let finalRefreshAckTimeoutSeconds = 10
private let maximumRepairRequests = 16

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

    var description: String {
        String(
            format: "session=%u active=%@ pending=%@ blockReceived=%@ lastAccepted=%@ generated=%u attempts=%u accepted=%u rejected=%u requestedBlock=%u previousStatus=0x%02X lastNotifyResult=0x%02X lastReceivedBlock=%u",
            session,
            (flags & 0x01) != 0 ? "yes" : "no",
            (flags & 0x02) != 0 ? "yes" : "no",
            (flags & 0x04) != 0 ? "yes" : "no",
            (flags & 0x08) != 0 ? "yes" : "no",
            generatedCount,
            notifyAttemptCount,
            notifyAcceptedCount,
            notifyRejectedCount,
            requestedBlock,
            previousBlockStatus,
            lastNotifyResult,
            lastReceivedBlock
        )
    }
}

private final class MacImageTransfer: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private lazy var central = CBCentralManager(delegate: self, queue: queue)
    private let queue = DispatchQueue(label: "com.todoocard.mac-image-transfer")
    private let payloadURL: URL
    private let legacyPayloadURL: URL?
    private let rawPayloadURL: URL?
    private let requestedProfile: Profile
    private let targetID: UUID?
    private let listOnly: Bool
    private let probeOnly: Bool
    private let pairOnly: Bool
    private let allowDeviceButton: Bool
    private var seenIDs = Set<UUID>()
    private var payload = Data()
    private var latestPayload = Data()
    private var legacyPayload = Data()
    private var rawPayload = Data()
    private var activeProfile: Profile
    private var usesVerifiedWindows = false
    private var peripheral: CBPeripheral?
    private var advertisedInfo: TodooAdvertisement?
    private var imageService: CBService?
    private var controlCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var diagnosticsCharacteristic: CBCharacteristic?
    private var secureLinkVerified = false
    private var pairingSucceeded = false
    private var pairingWindowHintShown = false
    private var connectionAttempt = 0
    private var serviceDiscoveryCompleted = false
    private var notificationSettled = false
    private var notificationSettleScheduled = false
    private var transferStarted = false
    private var blockPayloadSize = 0
    private var nextCompressedBlockIndex: Int?
    private var nextVerifiedBlockIndex: Int?
    private var verifiedWindowStart = 0
    private var verifiedWindowEnd = 0
    private var lastSentBlockIndex = -1
    private var repairRequestCount = 0
    private var completePayloadWritten = false
    private var finalTransferAckReceived = false
    private var verifiedWriteResponsePending = false
    private var earlyVerifiedRequestedBlock: Int?
    private var lastProgress = -1
    private var finalAckTimer: DispatchSourceTimer?
    private var checkpointAckTimer: DispatchSourceTimer?
    private var controlResponseTimer: DispatchSourceTimer?
    private var controlFallbackTimer: DispatchSourceTimer?
    private var lastControlCommand: UInt8?
    private var retriedControlWithoutResponse = false
    private var pendingFailureExitCode: Int32?
    private var pendingFailureMessage: String?
    private var diagnosticReadPending = false
    private var probeCompletionScheduled = false

    init(payloadURL: URL, legacyPayloadURL: URL?, rawPayloadURL: URL?, profile: Profile, targetID: UUID?, listOnly: Bool, probeOnly: Bool, pairOnly: Bool, allowDeviceButton: Bool) {
        self.payloadURL = payloadURL
        self.legacyPayloadURL = legacyPayloadURL
        self.rawPayloadURL = rawPayloadURL
        self.requestedProfile = profile
        self.activeProfile = profile
        self.targetID = targetID
        self.listOnly = listOnly
        self.probeOnly = probeOnly
        self.pairOnly = pairOnly
        self.allowDeviceButton = allowDeviceButton
        super.init()
    }

    func run() {
        if !listOnly, !probeOnly, !pairOnly {
            do {
                latestPayload = try Data(contentsOf: payloadURL)
                if let legacyPayloadURL {
                    legacyPayload = try Data(contentsOf: legacyPayloadURL)
                }
                if let rawPayloadURL {
                    rawPayload = try Data(contentsOf: rawPayloadURL)
                }
                payload = latestPayload
            } catch {
                log("Failed to read payload: \(error)")
                Foundation.exit(2)
            }
            log("Payload: \(payloadURL.path)")
            log("Latest payload size: \(latestPayload.count) bytes")
            if !legacyPayload.isEmpty { log("Legacy payload size: \(legacyPayload.count) bytes") }
            if !rawPayload.isEmpty { log("Raw payload size: \(rawPayload.count) bytes") }
            log("Requested profile: \(requestedProfile == .compressed ? "automatic T3" : "standard")")
        }
        _ = central
        dispatchMain()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            log("Bluetooth state: \(central.state.rawValue)")
            return
        }
        if listOnly {
            log("Scanning nearby BLE devices for 30s ...")
            queue.asyncAfter(deadline: .now() + .seconds(30)) { Foundation.exit(0) }
        } else if pairOnly {
            log("Waiting for the physical pairing window on the exact target UUID ...")
            log("Hold the rear button until the front light fast-flashes (5 seconds on current firmware; 10 seconds on older secure firmware).")
        } else if probeOnly {
            log("Scanning for probe target ...")
        } else {
            log("Scanning for image-transfer device ...")
        }
        if !listOnly {
            let scanTimeout = pairOnly ? 75 : 45
            queue.asyncAfter(deadline: .now() + .seconds(scanTimeout)) { [weak self] in
                guard let self, self.peripheral == nil else { return }
                if self.pairOnly {
                    log("Timed out waiting for the 60-second physical pairing window")
                } else {
                    log("Timed out scanning for target")
                }
                Foundation.exit(14)
            }
        }
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? ""
        let advertisement = parseTodooAdvertisement(
            advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        )
        if listOnly {
            guard !seenIDs.contains(peripheral.identifier) else { return }
            seenIDs.insert(peripheral.identifier)
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                .map(\.uuidString)
                .joined(separator: ",") ?? ""
            log("BLE \(name.isEmpty ? "(no name)" : name) id=\(peripheral.identifier) RSSI=\(RSSI) services=\(services) \(advertisementDescription(advertisement))")
            return
        }

        if let targetID, peripheral.identifier != targetID { return }

        guard let advertisement else {
            log("TodooCard manufacturer data is missing")
            Foundation.exit(20)
        }
        guard advertisement.manufacturerID == 0x5053,
              advertisement.screenType == 0x134C else {
            log("TodooCard identity mismatch: \(advertisementDescription(advertisement))")
            Foundation.exit(20)
        }
        if pairOnly {
            guard advertisement.requiresEncryptedGatt else {
                log("Target firmware does not use the latest secure pairing protocol")
                Foundation.exit(21)
            }
            guard advertisement.pairingWindowOpen else {
                if !pairingWindowHintShown {
                    pairingWindowHintShown = true
                    log("Target found, but pairing=closed; hold the rear button for \(advertisement.pairingHoldSeconds) seconds until the light fast-flashes.")
                }
                return
            }
            log("Physical pairing window detected; starting encrypted system pairing.")
        } else if advertisement.pairingWindowOpen {
            log("Refusing probe/transfer while the new-device pairing window is open; use --pair for a new Mac or wait for the window to close.")
            Foundation.exit(26)
        }
        if !pairOnly, !probeOnly, advertisement.otaRecoveryMode {
            log("Refusing image transfer: the device advertises OTA-only recovery mode. Repair the approved firmware first.")
            Foundation.exit(28)
        }

        advertisedInfo = advertisement
        if !listOnly, !probeOnly, !pairOnly {
            selectPayload(for: advertisement)
        }
        log("Advertisement verified: \(advertisementDescription(advertisement))")
        log("Found \(name.isEmpty ? peripheral.identifier.uuidString : name) id=\(peripheral.identifier) RSSI=\(RSSI)")
        self.peripheral = peripheral
        central.stopScan()
        peripheral.delegate = self
        connect(peripheral)
    }

    private func selectPayload(for advertisement: TodooAdvertisement) {
        activeProfile = requestedProfile
        usesVerifiedWindows = false
        if requestedProfile == .compressed,
           advertisement.firmwareVersion >= verifiedTransferMinimumVersion {
            let compressedTransferBytes = ((latestPayload.count + 239) / 240) * 240
            let rawTransferBytes = ((rawPayload.count + 239) / 240) * 240
            if !latestPayload.isEmpty,
               rawPayload.isEmpty || compressedTransferBytes < rawTransferBytes {
                payload = latestPayload
                activeProfile = .compressed
                log("Protocol selected: v157+ QuickLZ level-3 compressed payload (\(payload.count) bytes)")
            } else if !rawPayload.isEmpty {
                payload = rawPayload
                activeProfile = .standard
                log("Protocol selected: v157+ RAW payload because compression has no transfer benefit (\(payload.count) bytes)")
            }
            usesVerifiedWindows = true
            log("Verified transfer enabled: wait for a durable device checkpoint every \(verifiedWindowBlocks) blocks")
            return
        }
        if requestedProfile == .compressed, !legacyPayload.isEmpty {
            payload = legacyPayload
            activeProfile = .compressed
            log("Protocol selected: legacy QuickLZ-stored compatibility payload (\(payload.count) bytes)")
        } else if requestedProfile == .compressed {
            log("Refusing pre-v157 transfer because --legacy-payload was not supplied")
            Foundation.exit(31)
        } else {
            payload = latestPayload
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        connectionAttempt += 1
        let attempt = connectionAttempt
        log("Connecting (attempt \(attempt)/3) ...")
        central.connect(peripheral, options: nil)
        queue.asyncAfter(deadline: .now() + .seconds(15)) { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.peripheral === peripheral,
                  self.connectionAttempt == attempt,
                  peripheral.state != .connected else { return }
            log("Timed out connecting")
            Foundation.exit(15)
        }
    }

    private func retryEncryptionTimeout(_ peripheral: CBPeripheral, error: Error?) -> Bool {
        let systemError = error as NSError?
        guard advertisedInfo?.requiresEncryptedGatt == true,
              !secureLinkVerified,
              systemError?.domain == "CBErrorDomain",
              systemError?.code == 15,
              connectionAttempt < 3 else { return false }

        let delay = connectionAttempt == 1 ? 0.75 : 1.5
        imageService = nil
        controlCharacteristic = nil
        dataCharacteristic = nil
        batteryCharacteristic = nil
        diagnosticsCharacteristic = nil
        log("Encryption timed out; retrying the same explicit connection in \(delay)s.")
        queue.asyncAfter(deadline: .now() + delay) { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.peripheral === peripheral,
                  peripheral.state == .disconnected else { return }
            self.connect(peripheral)
        }
        return true
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected")
        serviceDiscoveryCompleted = false
        notificationSettled = false
        notificationSettleScheduled = false
        peripheral.discoverServices(nil)
        for delay in [3, 8] {
            queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self, weak peripheral] in
                guard let self, let peripheral,
                      self.peripheral === peripheral,
                      peripheral.state == .connected,
                      !self.serviceDiscoveryCompleted else { return }
                log("Service discovery has not completed; retrying")
                peripheral.discoverServices(nil)
            }
        }
        if pairOnly {
            queue.asyncAfter(deadline: .now() + .seconds(30)) { [weak self, weak peripheral] in
                guard let self, let peripheral,
                      self.peripheral === peripheral,
                      !self.pairingSucceeded else { return }
                log("Timed out completing encrypted system pairing")
                self.central.cancelPeripheralConnection(peripheral)
                Foundation.exit(27)
            }
        } else {
            queue.asyncAfter(deadline: .now() + .seconds(35)) { [weak self, weak peripheral] in
                guard let self, let peripheral,
                      self.peripheral === peripheral,
                      !self.transferStarted else { return }
                log("Timed out preparing the verified TodooCard GATT connection")
                self.central.cancelPeripheralConnection(peripheral)
                Foundation.exit(19)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if retryEncryptionTimeout(peripheral, error: error) { return }
        log("Connect failed: \(error?.localizedDescription ?? "unknown")")
        Foundation.exit(3)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected: \(error?.localizedDescription ?? "no error")")
        if retryEncryptionTimeout(peripheral, error: error) { return }
        checkpointAckTimer?.cancel()
        finalAckTimer?.cancel()
        controlResponseTimer?.cancel()
        controlFallbackTimer?.cancel()
        if pendingFailureExitCode != nil {
            finishPendingFailureIfNeeded(force: true)
            return
        }
        if pairOnly, !pairingSucceeded {
            log("Pairing did not complete; reopen the physical pairing window and try again.")
            Foundation.exit(27)
        }
        if advertisedInfo?.requiresEncryptedGatt == true, !secureLinkVerified {
            log("The secure bond is unavailable. Run --pair during a new physical pairing window, then probe again.")
            Foundation.exit(18)
        }
        if probeOnly {
            log("Probe ended before GATT verification completed")
            Foundation.exit(29)
        }
        if transferStarted {
            log(completePayloadWritten
                ? "Device disconnected after the payload was written but before the required 0x05/0x08 refresh acknowledgement. Treating this run as unconfirmed."
                : "Device disconnected before the image payload completed.")
            if (advertisedInfo?.firmwareVersion ?? 0) >= imageAckDiagnosticsMinimumVersion {
                log("Reconnect with --probe to read the retained image-ACK diagnostics.")
            }
            Foundation.exit(29)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Discover services failed: \(error)")
            Foundation.exit(4)
        }
        serviceDiscoveryCompleted = true
        guard let services = peripheral.services, !services.isEmpty else {
            log("Image-transfer service not found")
            Foundation.exit(5)
        }
        log("Services ready: \(services.map(\.uuid.uuidString).joined(separator: ","))")
        imageService = services.first { serviceUUIDs.contains($0.uuid) }

        if advertisedInfo?.requiresEncryptedGatt == true, !secureLinkVerified {
            guard let batteryService = services.first(where: { $0.uuid == batteryServiceUUID }) else {
                log("Encrypted Battery Service is missing; cannot verify the secure bond")
                Foundation.exit(18)
            }
            peripheral.discoverCharacteristics(
                [batteryLevelCharacteristicUUID],
                for: batteryService
            )
            return
        }

        guard let imageService else {
            log("Image-transfer service not found after secure pairing")
            Foundation.exit(5)
        }
        peripheral.discoverCharacteristics(
            controlCharacteristicUUIDs + dataCharacteristicUUIDs,
            for: imageService
        )
        if (advertisedInfo?.firmwareVersion ?? 0) >= imageAckDiagnosticsMinimumVersion,
           let diagnosticsService = services.first(where: { $0.uuid == diagnosticsServiceUUID }) {
            peripheral.discoverCharacteristics(
                [imageAckDiagnosticsCharacteristicUUID],
                for: diagnosticsService
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("Discover characteristics failed for \(service.uuid.uuidString): \(error)")
            Foundation.exit(6)
        }
        service.characteristics?.forEach { characteristic in
            if probeOnly || pairOnly {
                log("Characteristic service=\(service.uuid.uuidString) uuid=\(characteristic.uuid.uuidString) props=\(Self.propertiesDescription(characteristic.properties))")
            }
            if controlCharacteristicUUIDs.contains(characteristic.uuid) {
                controlCharacteristic = characteristic
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if dataCharacteristicUUIDs.contains(characteristic.uuid) {
                dataCharacteristic = characteristic
            } else if characteristic.uuid == batteryLevelCharacteristicUUID {
                batteryCharacteristic = characteristic
            } else if characteristic.uuid == imageAckDiagnosticsCharacteristicUUID {
                diagnosticsCharacteristic = characteristic
                if characteristic.properties.contains(.read), probeOnly {
                    log("Reading retained image-ACK diagnostics ...")
                    peripheral.readValue(for: characteristic)
                }
            }
        }

        if service.uuid == batteryServiceUUID {
            guard let batteryCharacteristic else {
                log("Encrypted Battery Level characteristic is missing")
                Foundation.exit(18)
            }
            log(pairOnly
                ? "Requesting encrypted Battery Level to create and verify the system bond ..."
                : "Verifying the existing encrypted system bond ...")
            peripheral.readValue(for: batteryCharacteristic)
            return
        }

        if probeOnly,
           controlCharacteristic != nil,
           dataCharacteristic != nil,
           (advertisedInfo?.requiresEncryptedGatt != true || secureLinkVerified) {
            scheduleProbeCompletion()
            return
        }
        beginIfReady()
    }

    private func scheduleProbeCompletion() {
        guard !probeCompletionScheduled else { return }
        probeCompletionScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(1200)) { [weak self] in
            guard let self else { return }
            self.transferStarted = true
            log("Probe completed: exact UUID, manufacturer=0x5053, screen=0x134C, and secure FEF1/FEF2 access verified")
            if (self.advertisedInfo?.firmwareVersion ?? 0) >= imageAckDiagnosticsMinimumVersion,
               self.diagnosticsCharacteristic == nil {
                log("Image-ACK diagnostics were advertised by firmware version but the readable endpoint was unavailable")
            }
            Foundation.exit(0)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("Enable notify failed: \(error)")
            Foundation.exit(7)
        }
        guard !notificationSettleScheduled else { return }
        notificationSettleScheduled = true
        log("Control notification enabled; settling for 400ms")
        queue.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            guard let self else { return }
            self.notificationSettled = true
            self.beginIfReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == imageAckDiagnosticsCharacteristicUUID {
            diagnosticReadPending = false
            if let error {
                log("Image-ACK diagnostics read failed: \(error.localizedDescription)")
            } else if let data = characteristic.value,
                      let diagnostics = ImageAckDiagnostics.parse(data) {
                log("Image-ACK diagnostics: \(diagnostics.description)")
            } else {
                let hex = characteristic.value?.map { String(format: "%02x", $0) }.joined(separator: " ") ?? "empty"
                log("Image-ACK diagnostics were malformed: \(hex)")
            }
            finishPendingFailureIfNeeded()
            return
        }
        if characteristic.uuid == batteryLevelCharacteristicUUID {
            if let error {
                log("Encrypted pairing verification failed: \(error)")
                Foundation.exit(pairOnly ? 27 : 18)
            }
            guard let data = characteristic.value, data.count == 1 else {
                log("Encrypted Battery Level returned an invalid value")
                Foundation.exit(pairOnly ? 27 : 18)
            }
            secureLinkVerified = true
            log("Encrypted link verified; battery=\(data[0])%")
            if pairOnly {
                pairingSucceeded = true
                log("Pairing completed. The macOS system bond is ready for a separate --probe.")
                Foundation.exit(0)
            }
            log("Encrypted link ready; allowing 1.8s for Service Changed cache refresh")
            imageService = nil
            controlCharacteristic = nil
            dataCharacteristic = nil
            diagnosticsCharacteristic = nil
            notificationSettled = false
            notificationSettleScheduled = false
            serviceDiscoveryCompleted = false
            queue.asyncAfter(deadline: .now() + .milliseconds(1800)) { [weak self, weak peripheral] in
                guard let self, let peripheral,
                      self.peripheral === peripheral,
                      peripheral.state == .connected else { return }
                log("Rediscovering transfer services after secure cache refresh")
                peripheral.discoverServices(nil)
            }
            return
        }
        if let error {
            failTransfer("Control notification failed: \(error.localizedDescription)", exitCode: 8)
            return
        }
        guard let data = characteristic.value else { return }
        handleControlMessage(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            failTransfer(
                "Write failed for \(characteristic.uuid.uuidString): \(error.localizedDescription)",
                exitCode: 17
            )
            return
        }
        if dataCharacteristicUUIDs.contains(characteristic.uuid),
           usesVerifiedWindows,
           verifiedWriteResponsePending {
            verifiedWriteResponsePending = false
            if let nextVerifiedBlockIndex, nextVerifiedBlockIndex < verifiedWindowEnd {
                pumpVerifiedWindow()
            } else {
                finishQueuedVerifiedWindow()
            }
            return
        }
        if controlCharacteristicUUIDs.contains(characteristic.uuid) {
            log("Control write accepted for \(characteristic.uuid.uuidString)")
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if usesVerifiedWindows {
            pumpVerifiedWindow()
        } else if activeProfile == .compressed {
            pumpCompressed()
        }
    }

    private func beginIfReady() {
        guard !probeOnly, !pairOnly else { return }
        guard peripheral != nil, let controlCharacteristic, dataCharacteristic != nil else { return }
        guard advertisedInfo?.requiresEncryptedGatt != true || secureLinkVerified else { return }
        guard !transferStarted else { return }
        let waits = controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate)
        guard !waits || (controlCharacteristic.isNotifying && notificationSettled) else { return }
        transferStarted = true
        log("Characteristics ready: control=\(controlCharacteristic.uuid.uuidString), data=\(dataCharacteristic?.uuid.uuidString ?? "")")
        log("Control props: \(Self.propertiesDescription(controlCharacteristic.properties))")
        if let dataCharacteristic {
            log("Data props: \(Self.propertiesDescription(dataCharacteristic.properties))")
        }
        writeCommand(Data([Command.requestBlockSize.rawValue]))
    }

    private func writeCommand(_ data: Data) {
        guard let peripheral, let controlCharacteristic else { return }
        // Native CoreBluetooth provides a definitive ATT result for
        // withResponse. If that path stalls, the 600ms fallback below retries
        // the same command withoutResponse, matching the current App flow.
        let type: CBCharacteristicWriteType = controlCharacteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        lastControlCommand = data.first
        retriedControlWithoutResponse = false
        startControlResponseTimer(command: data.first, originalData: data, writeType: type)
        startControlFallbackTimer(command: data.first, originalData: data)
        log("Control -> \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
        peripheral.writeValue(data, for: controlCharacteristic, type: type)
    }

    private func handleControlMessage(_ data: Data) {
        let bytes = [UInt8](data)
        guard let first = bytes.first, let command = Command(rawValue: first) else {
            log("Control <- \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
            return
        }
        controlResponseTimer?.cancel()
        controlResponseTimer = nil
        controlFallbackTimer?.cancel()
        controlFallbackTimer = nil
        retriedControlWithoutResponse = false
        lastControlCommand = nil
        log("Control <- \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
        switch command {
        case .requestBlockSize:
            guard bytes.count >= 3, bytes[2] == Status.success.rawValue else {
                failTransfer("Block size request was rejected", exitCode: 9)
                return
            }
            blockPayloadSize = max(0, Int(bytes[1]) - 4)
            guard blockPayloadSize > 0 else {
                failTransfer("Device returned an invalid block size: \(bytes[1])", exitCode: 9)
                return
            }
            log("Block payload size: \(blockPayloadSize)")
            requestScreenSize()
        case .requestScreenSize:
            guard bytes.count >= 2, bytes[1] == Status.success.rawValue else {
                failTransfer("Payload length was rejected", exitCode: 10)
                return
            }
            writeCommand(Data([Command.requestStartTransfer.rawValue]))
        case .dataAck:
            guard bytes.count >= 2 else { return }
            if bytes[1] == Status.transferEnd.rawValue {
                if usesVerifiedWindows, !completePayloadWritten {
                    finalTransferAckReceived = true
                    log("Refresh acknowledgement arrived while the final local write was settling; retaining it until the payload queue completes")
                    return
                }
                finishSuccessfulTransfer()
                return
            }
            guard bytes[1] == Status.success.rawValue else {
                failTransfer(transferErrorMessage(status: bytes[1]), exitCode: 11)
                return
            }
            guard bytes.count >= 6 else {
                failTransfer("Device returned a malformed data acknowledgement", exitCode: 11)
                return
            }
            let index = Int(bytes[2]) | Int(bytes[3]) << 8 | Int(bytes[4]) << 16 | Int(bytes[5]) << 24
            if usesVerifiedWindows {
                checkpointAckTimer?.cancel()
                checkpointAckTimer = nil
                if nextVerifiedBlockIndex != nil || verifiedWriteResponsePending {
                    earlyVerifiedRequestedBlock = index
                    log("Device checkpoint arrived while the local queue was settling: requested block \(index)")
                    return
                }
                beginVerifiedWindow(at: index)
            } else if activeProfile == .compressed {
                nextCompressedBlockIndex = index
                pumpCompressed()
            } else {
                sendStandardBlock(index)
            }
        default:
            break
        }
    }

    private func requestScreenSize() {
        if activeProfile == .compressed {
            let remainder = payload.count % blockPayloadSize
            if remainder != 0 {
                let padding = blockPayloadSize - remainder
                payload.append(Data(repeating: 0, count: padding))
                log("Compressed payload padded by \(padding) bytes to \(payload.count) for \(blockPayloadSize)-byte blocks")
            }
        }
        var data = Data([Command.requestScreenSize.rawValue])
        data.append(UInt8(payload.count & 0xff))
        data.append(UInt8((payload.count >> 8) & 0xff))
        data.append(UInt8((payload.count >> 16) & 0xff))
        data.append(UInt8((payload.count >> 24) & 0xff))
        var flags: UInt8 = activeProfile == .compressed ? 0x01 : 0x03
        if allowDeviceButton { flags |= 0x10 }
        data.append(flags)
        writeCommand(data)
    }

    private func makeBlock(index: Int) -> (packet: Data, percent: Int, isLast: Bool)? {
        guard blockPayloadSize > 0 else { return nil }
        let offset = index * blockPayloadSize
        guard offset < payload.count else { return nil }
        let length = min(blockPayloadSize, payload.count - offset)
        var packet = Data()
        packet.append(UInt8(index & 0xff))
        packet.append(UInt8((index >> 8) & 0xff))
        packet.append(UInt8((index >> 16) & 0xff))
        packet.append(UInt8((index >> 24) & 0xff))
        packet.append(payload.subdata(in: offset ..< offset + length))
        let written = offset + length
        return (packet, Int(Double(written) / Double(payload.count) * 100), written >= payload.count)
    }

    private var totalBlockCount: Int {
        guard blockPayloadSize > 0 else { return 0 }
        return (payload.count + blockPayloadSize - 1) / blockPayloadSize
    }

    private func beginVerifiedWindow(at index: Int) {
        let totalBlocks = totalBlockCount
        guard index >= 0, index <= totalBlocks else {
            failTransfer(
                "Device returned invalid resume block \(index); total blocks=\(totalBlocks)",
                exitCode: 11
            )
            return
        }
        if index == totalBlocks {
            guard completePayloadWritten || lastSentBlockIndex >= totalBlocks - 1 else {
                failTransfer("Device skipped past payload data at block \(index)", exitCode: 11)
                return
            }
            completePayloadWritten = true
            log("Device checkpoint covers all \(totalBlocks) blocks; waiting for refresh acknowledgement")
            waitForFinalAck(seconds: finalRefreshAckTimeoutSeconds)
            return
        }

        if lastSentBlockIndex >= 0 {
            guard index <= verifiedWindowEnd else {
                failTransfer(
                    "Device checkpoint skipped from window end \(verifiedWindowEnd) to block \(index)",
                    exitCode: 11
                )
                return
            }
            if index < verifiedWindowEnd {
                repairRequestCount += 1
                guard repairRequestCount <= maximumRepairRequests else {
                    failTransfer(
                        "Device requested too many block repairs (\(repairRequestCount)); move the Mac closer and retry",
                        exitCode: 30
                    )
                    return
                }
                log("Device verified only through block \(index); repairing the unfinished window (\(repairRequestCount)/\(maximumRepairRequests))")
            } else {
                repairRequestCount = 0
                log("Durable Flash checkpoint accepted through block \(index)")
            }
        } else {
            log("Device requested initial block \(index)")
        }

        finalAckTimer?.cancel()
        finalAckTimer = nil
        completePayloadWritten = false
        verifiedWindowStart = index
        verifiedWindowEnd = min(((index / verifiedWindowBlocks) + 1) * verifiedWindowBlocks, totalBlocks)
        nextVerifiedBlockIndex = index
        earlyVerifiedRequestedBlock = nil
        log("Verified window: [\(verifiedWindowStart), \(verifiedWindowEnd)) of \(totalBlocks) blocks")
        pumpVerifiedWindow()
    }

    private func pumpVerifiedWindow() {
        guard usesVerifiedWindows,
              !verifiedWriteResponsePending,
              let peripheral,
              let dataCharacteristic,
              var index = nextVerifiedBlockIndex else { return }

        let supportsNoResponse = dataCharacteristic.properties.contains(.writeWithoutResponse)
        let supportsResponse = dataCharacteristic.properties.contains(.write)
        guard supportsNoResponse || supportsResponse else {
            failTransfer("Data characteristic supports neither write mode", exitCode: 12)
            return
        }

        while index < verifiedWindowEnd {
            guard let block = makeBlock(index: index) else {
                failTransfer("Could not build data block \(index)", exitCode: 12)
                return
            }
            let isBarrier = index + 1 >= verifiedWindowEnd
            if supportsResponse && (isBarrier || !supportsNoResponse) {
                verifiedWriteResponsePending = true
                nextVerifiedBlockIndex = index + 1
                lastSentBlockIndex = max(lastSentBlockIndex, index)
                peripheral.writeValue(block.packet, for: dataCharacteristic, type: .withResponse)
                emitProgress(block.percent, index: index)
                return
            }
            guard peripheral.canSendWriteWithoutResponse else {
                nextVerifiedBlockIndex = index
                return
            }
            peripheral.writeValue(block.packet, for: dataCharacteristic, type: .withoutResponse)
            lastSentBlockIndex = max(lastSentBlockIndex, index)
            emitProgress(block.percent, index: index)
            index += 1
            nextVerifiedBlockIndex = index
        }
        finishQueuedVerifiedWindow()
    }

    private func finishQueuedVerifiedWindow() {
        guard nextVerifiedBlockIndex != nil else { return }
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
            self.earlyVerifiedRequestedBlock = nil
            beginVerifiedWindow(at: earlyRequestedBlock)
            return
        }
        if isFinalWindow {
            log("Payload queue completed; waiting for required 0x05/0x08 refresh acknowledgement")
            waitForFinalAck(seconds: finalRefreshAckTimeoutSeconds)
        } else {
            log("Window queued through block \(verifiedWindowEnd); waiting for durable Flash checkpoint")
            armCheckpointWait()
        }
    }

    private func armCheckpointWait() {
        checkpointAckTimer?.cancel()
        let expectedWindowStart = verifiedWindowStart
        let expectedWindowEnd = verifiedWindowEnd
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(verifiedCheckpointTimeoutSeconds))
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.nextVerifiedBlockIndex == nil,
                  self.verifiedWindowStart == expectedWindowStart,
                  self.verifiedWindowEnd == expectedWindowEnd else { return }
            guard self.repairRequestCount < maximumRepairRequests else {
                self.failTransfer(
                    "Timed out waiting for the durable checkpoint after \(maximumRepairRequests) probes",
                    exitCode: 30
                )
                return
            }
            self.repairRequestCount += 1
            let probeIndex = max(expectedWindowEnd - 1, expectedWindowStart)
            guard let peripheral = self.peripheral,
                  let characteristic = self.dataCharacteristic,
                  let block = self.makeBlock(index: probeIndex) else {
                self.failTransfer("Unable to probe checkpoint progress", exitCode: 30)
                return
            }
            let type: CBCharacteristicWriteType = characteristic.properties.contains(.write)
                ? .withResponse
                : .withoutResponse
            log("Checkpoint timeout; re-sending window-end block \(probeIndex) to request device progress (\(self.repairRequestCount)/\(maximumRepairRequests))")
            peripheral.writeValue(block.packet, for: characteristic, type: type)
            self.armCheckpointWait()
        }
        checkpointAckTimer = timer
        timer.resume()
    }

    private func sendStandardBlock(_ index: Int) {
        guard let peripheral, let dataCharacteristic, let block = makeBlock(index: index) else { return }
        let type: CBCharacteristicWriteType = dataCharacteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(block.packet, for: dataCharacteristic, type: type)
        emitProgress(block.percent, index: index)
        if block.isLast {
            completePayloadWritten = true
            waitForFinalAck(seconds: 5)
        }
    }

    private func pumpCompressed() {
        guard let peripheral, let dataCharacteristic else { return }
        guard dataCharacteristic.properties.contains(.writeWithoutResponse) else {
            failTransfer("Compressed transfer requires a writeWithoutResponse data characteristic", exitCode: 12)
            return
        }
        while peripheral.canSendWriteWithoutResponse {
            guard let index = nextCompressedBlockIndex, let block = makeBlock(index: index) else { return }
            peripheral.writeValue(block.packet, for: dataCharacteristic, type: .withoutResponse)
            emitProgress(block.percent, index: index)
            if block.isLast {
                nextCompressedBlockIndex = nil
                completePayloadWritten = true
                log("Payload written; waiting for refresh ack")
                waitForFinalAck(seconds: 90)
                return
            }
            nextCompressedBlockIndex = index + 1
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(6)) { [weak self] in
            self?.pumpCompressed()
        }
    }

    private func emitProgress(_ percent: Int, index: Int) {
        guard percent > lastProgress, percent.isMultiple(of: 5) || percent >= 100 else { return }
        lastProgress = percent
        log("Progress: \(percent)% block=\(index)")
    }

    private func waitForFinalAck(seconds: Int) {
        finalAckTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(seconds))
        timer.setEventHandler { [weak self] in
            self?.failTransfer(
                "Timed out waiting for the required 0x05/0x08 refresh acknowledgement",
                exitCode: 13
            )
        }
        finalAckTimer = timer
        timer.resume()
    }

    private func finishSuccessfulTransfer() {
        checkpointAckTimer?.cancel()
        checkpointAckTimer = nil
        finalAckTimer?.cancel()
        finalAckTimer = nil
        controlResponseTimer?.cancel()
        controlResponseTimer = nil
        controlFallbackTimer?.cancel()
        controlFallbackTimer = nil
        log("Transfer completed and refresh acknowledged by 0x05/0x08")
        Foundation.exit(0)
    }

    private func transferErrorMessage(status: UInt8) -> String {
        switch status {
        case 0x01:
            return "Device rejected a malformed or out-of-order image block (status 0x01)"
        case 0x09:
            return "External Flash write failed on the device (status 0x09)"
        case 0x0A:
            return "External Flash readback verification failed on the device (status 0x0A)"
        default:
            return String(format: "Device interrupted image transfer with status 0x%02X", status)
        }
    }

    private func failTransfer(_ message: String, exitCode: Int32) {
        guard pendingFailureExitCode == nil else { return }
        checkpointAckTimer?.cancel()
        checkpointAckTimer = nil
        finalAckTimer?.cancel()
        finalAckTimer = nil
        controlResponseTimer?.cancel()
        controlResponseTimer = nil
        controlFallbackTimer?.cancel()
        controlFallbackTimer = nil
        pendingFailureMessage = message
        pendingFailureExitCode = exitCode
        log("Transfer failed: \(message)")

        if (advertisedInfo?.firmwareVersion ?? 0) >= imageAckDiagnosticsMinimumVersion,
           let peripheral,
           peripheral.state == .connected,
           let diagnosticsCharacteristic,
           diagnosticsCharacteristic.properties.contains(.read) {
            diagnosticReadPending = true
            log("Reading retained v165+ image-ACK diagnostics before exiting ...")
            peripheral.readValue(for: diagnosticsCharacteristic)
            queue.asyncAfter(deadline: .now() + .milliseconds(1800)) { [weak self] in
                self?.finishPendingFailureIfNeeded(force: true)
            }
            return
        }
        if (advertisedInfo?.firmwareVersion ?? 0) >= imageAckDiagnosticsMinimumVersion {
            log("Reconnect with --probe to read retained image-ACK diagnostics.")
        }
        finishPendingFailureIfNeeded(force: true)
    }

    private func finishPendingFailureIfNeeded(force: Bool = false) {
        guard let exitCode = pendingFailureExitCode else { return }
        guard force || !diagnosticReadPending else { return }
        if let pendingFailureMessage {
            log("Failure summary: \(pendingFailureMessage)")
        }
        Foundation.exit(exitCode)
    }

    private func startControlResponseTimer(command: UInt8?, originalData: Data, writeType: CBCharacteristicWriteType) {
        controlResponseTimer?.cancel()
        guard command != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if writeType == .withResponse,
               !self.retriedControlWithoutResponse,
               let peripheral = self.peripheral,
               let controlCharacteristic = self.controlCharacteristic,
               controlCharacteristic.properties.contains(.writeWithoutResponse) {
                self.retriedControlWithoutResponse = true
                log("Control response timed out; retrying withoutResponse")
                peripheral.writeValue(originalData, for: controlCharacteristic, type: .withoutResponse)
                self.startControlResponseTimer(command: command, originalData: originalData, writeType: .withoutResponse)
                return
            }
            self.failTransfer("Control response timed out", exitCode: 16)
        }
        controlResponseTimer = timer
        timer.resume()
    }

    private func startControlFallbackTimer(command: UInt8?, originalData: Data) {
        controlFallbackTimer?.cancel()
        guard let command,
              let controlCharacteristic,
              controlCharacteristic.properties.contains(.writeWithoutResponse) else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(600))
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.lastControlCommand == command,
                  self.controlResponseTimer != nil,
                  !self.retriedControlWithoutResponse,
                  let peripheral = self.peripheral,
                  let controlCharacteristic = self.controlCharacteristic else { return }
            self.retriedControlWithoutResponse = true
            log("Control reply pending; retrying after 600ms withoutResponse")
            peripheral.writeValue(originalData, for: controlCharacteristic, type: .withoutResponse)
        }
        controlFallbackTimer = timer
        timer.resume()
    }

    private static func propertiesDescription(_ properties: CBCharacteristicProperties) -> String {
        var values: [String] = []
        if properties.contains(.broadcast) { values.append("broadcast") }
        if properties.contains(.read) { values.append("read") }
        if properties.contains(.writeWithoutResponse) { values.append("writeWithoutResponse") }
        if properties.contains(.write) { values.append("write") }
        if properties.contains(.notify) { values.append("notify") }
        if properties.contains(.indicate) { values.append("indicate") }
        return values.joined(separator: ",")
    }
}

private func usage() -> Never {
    log("""
    Usage:
      MacImageTransfer --list
      MacImageTransfer --pair --id UUID
      MacImageTransfer --probe --id UUID
      MacImageTransfer --payload /path/final-180.protocol.qlz \
        --legacy-payload /path/final-180.protocol.legacy.qlz \
        --raw-payload /path/final-180.controller.bin --compressed --id UUID
      MacImageTransfer --payload /path/file.bin --standard --id UUID
    """)
    Foundation.exit(64)
}

private var payloadPath: String?
private var legacyPayloadPath: String?
private var rawPayloadPath: String?
private var profile: Profile = .compressed
private var targetID: UUID?
private var listOnly = false
private var probeOnly = false
private var pairOnly = false
private var allowDeviceButton = false
private var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--list":
        listOnly = true
    case "--probe":
        probeOnly = true
    case "--pair":
        pairOnly = true
    case "--payload":
        guard !args.isEmpty else { usage() }
        payloadPath = args.removeFirst()
    case "--legacy-payload":
        guard !args.isEmpty else { usage() }
        legacyPayloadPath = args.removeFirst()
    case "--raw-payload":
        guard !args.isEmpty else { usage() }
        rawPayloadPath = args.removeFirst()
    case "--compressed":
        profile = .compressed
    case "--standard":
        profile = .standard
    case "--id":
        guard !args.isEmpty, let uuid = UUID(uuidString: args.removeFirst()) else { usage() }
        targetID = uuid
    case "--allow-device-button":
        allowDeviceButton = true
    default:
        usage()
    }
}

let payloadURL = URL(fileURLWithPath: payloadPath ?? "/dev/null")
if (listOnly ? 1 : 0) + (probeOnly ? 1 : 0) + (pairOnly ? 1 : 0) > 1 {
    usage()
}
if !listOnly, !probeOnly, !pairOnly, payloadPath == nil {
    usage()
}
if !listOnly, targetID == nil {
    usage()
}
MacImageTransfer(
    payloadURL: payloadURL,
    legacyPayloadURL: legacyPayloadPath.map { URL(fileURLWithPath: $0) },
    rawPayloadURL: rawPayloadPath.map { URL(fileURLWithPath: $0) },
    profile: profile,
    targetID: targetID,
    listOnly: listOnly,
    probeOnly: probeOnly,
    pairOnly: pairOnly,
    allowDeviceButton: allowDeviceButton
).run()
