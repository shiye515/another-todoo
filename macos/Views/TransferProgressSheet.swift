import SwiftUI

/// 发送到设备的进度弹窗：展示扫描/连接/传输各阶段状态、进度与失败诊断。
struct TransferProgressSheet: View {
    @ObservedObject var transferService: TodooCardTransferService
    let controllerPayload: Data
    let deviceID: UUID

    @AppStorage("defaultTodooCardDeviceName") private var deviceName = ""
    @Environment(\.dismiss) private var dismiss
    @State private var autoDismissTask: Task<Void, Never>?

    private var isActive: Bool { transferService.isTransferActive }

    private var deviceLabel: String {
        deviceName.isEmpty ? deviceID.uuidString : deviceName
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            deviceInfo
            progressSection
            if let diagnostics = transferService.diagnosticsText, transferService.phase == .failed {
                diagnosticsSection(diagnostics)
            }
            controls
        }
        .padding(28)
        .frame(width: 440)
        .onAppear {
            transferService.startTransfer(controllerPayload: controllerPayload, deviceID: deviceID)
        }
        .onChange(of: transferService.phase) { phase in
            if phase == .succeeded {
                scheduleAutoDismiss()
            }
        }
        .onDisappear {
            autoDismissTask?.cancel()
            autoDismissTask = nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            phaseIcon
                .font(.system(size: 34))
            VStack(alignment: .leading, spacing: 4) {
                Text("发送到设备")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(transferService.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch transferService.phase {
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.orange)
        default:
            Image(systemName: "paperplane.circle.fill")
                .foregroundStyle(.blue)
        }
    }

    private var deviceInfo: some View {
        HStack(spacing: 8) {
            Image(systemName: "e.reader")
                .foregroundStyle(.secondary)
            Text(deviceLabel)
                .fontWeight(.medium)
                .textSelection(.enabled)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(controllerPayload.count), countStyle: .file))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private var progressSection: some View {
        switch transferService.phase {
        case .scanning, .connecting, .verifying, .negotiating:
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
        case .transferring, .waitingRefresh:
            VStack(spacing: 8) {
                ProgressView(value: transferService.progress)
                HStack {
                    Text("\(Int(transferService.progress * 100))%")
                        .font(.callout)
                        .monospacedDigit()
                    Spacer()
                    Text(byteProgressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        case .succeeded:
            Label("图片已发送，设备正在刷新画面", systemImage: "sparkles")
                .font(.callout)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity)
        case .failed:
            Label(transferService.lastError ?? "传输失败", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .cancelled:
            Label("传输已取消", systemImage: "stop.circle")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
        case .idle:
            EmptyView()
        }
    }

    private var byteProgressText: String {
        ByteCountFormatter.string(fromByteCount: Int64(transferService.bytesSent), countStyle: .file) +
            " / " +
            ByteCountFormatter.string(fromByteCount: Int64(transferService.bytesTotal), countStyle: .file)
    }

    private func diagnosticsSection(_ diagnostics: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设备诊断")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(diagnostics)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var controls: some View {
        HStack {
            Spacer()
            if isActive {
                Button("取消传输", role: .destructive) {
                    transferService.cancel()
                }
            } else {
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
