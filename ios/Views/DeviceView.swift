import SwiftUI

/// 设备页：蓝牙状态、扫描附近 TodooCard、设置/取消默认发送设备。
struct DeviceView: View {
    @ObservedObject var scanner: DeviceScanner
    @AppStorage("defaultTodooCardDeviceID") private var defaultDeviceID = ""
    @AppStorage("defaultTodooCardDeviceName") private var defaultDeviceName = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let scanError = scanner.scanError {
                    Label(scanError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if !defaultDeviceID.isEmpty {
                    defaultDeviceCard
                }
                if scanner.devices.isEmpty {
                    emptyState
                } else {
                    deviceList
                }
            }
            .padding(.horizontal, 16)
            .navigationTitle("设备")
            .onAppear {
                if !scanner.isScanning {
                    scanner.startScan()
                }
            }
            .onDisappear {
                scanner.stopScan()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("蓝牙设备")
                    .font(.headline)
                Text(scanner.bluetoothStateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if scanner.isScanning {
                    scanner.stopScan()
                } else {
                    scanner.startScan()
                }
            } label: {
                if scanner.isScanning {
                    Label("停止扫描", systemImage: "stop.circle")
                } else {
                    Label("扫描设备", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            .disabled(scanner.bluetoothState != .ready && scanner.bluetoothState != .initializing)
        }
        .padding(.top, 8)
    }

    private var defaultDeviceCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("默认设备")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(defaultDeviceName.isEmpty ? defaultDeviceID : defaultDeviceName)
                    .fontWeight(.medium)
            }
            Spacer()
            Button("取消默认") {
                clearDefaultDevice()
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(scanner.isScanning ? "正在扫描附近的 TodooCard…" : "未发现设备")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var deviceList: some View {
        List {
            ForEach(scanner.devices) { device in
                DeviceRow(
                    device: device,
                    isDefault: defaultDeviceID == device.id.uuidString,
                    setDefault: { setDefaultDevice(device) }
                )
            }
        }
        .listStyle(.inset)
    }

    private func setDefaultDevice(_ device: TodooCardDevice) {
        defaultDeviceID = device.id.uuidString
        defaultDeviceName = device.displayName
    }

    private func clearDefaultDevice() {
        defaultDeviceID = ""
        defaultDeviceName = ""
    }
}

private struct DeviceRow: View {
    let device: TodooCardDevice
    let isDefault: Bool
    let setDefault: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "e.reader")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .fontWeight(.semibold)
                    if isDefault {
                        Text("默认")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.accentColor.opacity(0.15))
                            )
                    }
                }
                Text(device.id.uuidString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    Text(device.firmwareDescription)
                    Text(device.statusDescription)
                    if device.turboLink {
                        Text("Turbo")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(device.rssi) dBm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(isDefault ? "已设为默认" : "设为默认") {
                    setDefault()
                }
                .disabled(isDefault)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
