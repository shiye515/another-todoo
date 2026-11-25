import AppKit
import SwiftUI

/// 待发送到设备的一次传输任务（驱动 `.sheet(item:)` 呈现进度弹窗）。
private struct PendingTransfer: Identifiable {
    let id = UUID()
    let payload: Data
    let deviceID: UUID
}

/// 图片页：图片库列表（纯列表布局，无处理区）。
/// 每个条目旁提供量化图发送、抖动图发送、重新量化与删除操作。
struct ImageView: View {
    @ObservedObject var processor: ImageProcessor
    @ObservedObject var library: ImageLibrary
    @ObservedObject var transferService: TodooCardTransferService
    @AppStorage("defaultTodooCardDeviceID") private var defaultDeviceID = ""

    @State private var pendingTransfer: PendingTransfer?
    /// payload 后台编码中的条目（按钮转圈）。
    @State private var encodingEntryID: UUID?
    @State private var isCanvasInteracting = false

    /// 任何传输/编码进行中，全部发送与重新量化按钮禁用（蓝牙单连接，防并发）。
    private var sendDisabled: Bool {
        pendingTransfer != nil || transferService.isTransferActive || encodingEntryID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            errorBanner
                .padding(.horizontal, 24)
                .padding(.top, 16)
            if library.entries.isEmpty {
                emptyState
            } else {
                entryList
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    beginAdd()
                } label: {
                    Label("添加图片", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(processor.isCropping || processor.isProcessingAdd)
            }
        }
        .sheet(item: $pendingTransfer) { transfer in
            TransferProgressSheet(
                transferService: transferService,
                controllerPayload: transfer.payload,
                deviceID: transfer.deviceID
            )
        }
        .sheet(isPresented: Binding(
            get: { processor.isCropping },
            set: { presented in
                if !presented {
                    processor.cancelCrop()
                }
            }
        )) {
            CropSheetView(processor: processor, isInteracting: $isCanvasInteracting)
                .interactiveDismissDisabled()
        }
    }

    // MARK: - 子视图

    private var errorBanner: some View {
        Group {
            if let message = library.lastError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if let message = processor.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("图片库为空")
                .font(.title3)
                .fontWeight(.semibold)
            Text("点击右上角“添加图片”（⌘O），裁剪确认后图片将保存到这里，重启不会丢失。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var entryList: some View {
        List {
            ForEach(library.entries) { entry in
                EntryRow(
                    entry: entry,
                    thumbnail: library.image(for: entry, kind: .processed),
                    isTransferring: transferService.isTransferActive,
                    isEncoding: encodingEntryID == entry.id,
                    isRequantizing: library.requantizingIDs.contains(entry.id),
                    canOperate: !sendDisabled,
                    send: { send(entry, kind: $0) },
                    requantize: { Task { try? await library.requantize(entry) } },
                    remove: { library.remove(entry) }
                )
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - 操作

    private func beginAdd() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.message = "选择要添加的图片，确认裁剪后将保存到图片库（不保留原图）。"

        guard panel.runModal() == .OK else { return }
        processor.beginAdd(urls: panel.urls)
    }

    private func send(_ entry: LibraryImage, kind: ImageLibrary.ImageKind) {
        guard !sendDisabled, encodingEntryID == nil else { return }
        guard let deviceID = UUID(uuidString: defaultDeviceID) else {
            processor.setErrorMessage("默认设备 ID 无效，请到“设备”页重新设置默认设备。")
            return
        }
        encodingEntryID = entry.id
        Task {
            defer { encodingEntryID = nil }
            do {
                guard let image = library.image(for: entry, kind: kind) else {
                    processor.setErrorMessage("量化图缺失且自动补建失败，请尝试“重新量化”。")
                    return
                }
                let payload = try await processor.makeControllerPayload(for: image)
                pendingTransfer = PendingTransfer(payload: payload, deviceID: deviceID)
            } catch {
                processor.setErrorMessage(error.localizedDescription)
            }
        }
    }
}

/// 图片库列表行：缩略图 + 名称/日期 + 发送/重新量化/删除按钮组。
private struct EntryRow: View {
    let entry: LibraryImage
    let thumbnail: NSImage?
    let isTransferring: Bool
    let isEncoding: Bool
    let isRequantizing: Bool
    let canOperate: Bool
    let send: (ImageLibrary.ImageKind) -> Void
    let requantize: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            thumbnailView
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(entry.addedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Button("量化图发送") {
                    send(.quantized)
                }
                Button("抖动图发送") {
                    send(.dithered)
                }
                if isRequantizing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 66)
                } else {
                    Button {
                        requantize()
                    } label: {
                        Label("重新量化", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isTransferring)
                }
            }
            .controlSize(.small)
            .disabled(isEncoding || !canOperate)

            Button {
                remove()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("从图片库删除该条目")
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }
}
