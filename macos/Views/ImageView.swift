import AppKit
import SwiftUI

/// 待发送到设备的一次传输任务（驱动 `.sheet(item:)` 呈现进度弹窗）。
private struct PendingTransfer: Identifiable {
    let id = UUID()
    let payload: Data
    let deviceID: UUID
}

/// 图片页：左侧库列表（资产管理）+ 右侧详情区（成品图与量化变体预览）。
/// 发送模型为「点击变体卡片选中 + 底部统一发送」，选中状态随条目持久化。
struct ImageView: View {
    @ObservedObject var processor: ImageProcessor
    @ObservedObject var library: ImageLibrary
    @ObservedObject var transferService: TodooCardTransferService
    @AppStorage("defaultTodooCardDeviceID") private var defaultDeviceID = ""

    @State private var selectedEntryID: UUID?
    @State private var pendingTransfer: PendingTransfer?
    /// payload 后台编码中的条目（按钮转圈）。
    @State private var encodingEntryID: UUID?
    @State private var isCanvasInteracting = false

    /// 任何传输/编码进行中，全部发送与重新量化按钮禁用（蓝牙单连接，防并发）。
    private var sendDisabled: Bool {
        pendingTransfer != nil || transferService.isTransferActive || encodingEntryID != nil
    }

    /// 当前详情区展示的条目（默认第一个）。
    private var selectedEntry: LibraryImage? {
        if let id = selectedEntryID, let entry = library.entries.first(where: { $0.id == id }) {
            return entry
        }
        return library.entries.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            errorBanner
                .padding(.horizontal, 24)
                .padding(.top, 16)
            if library.entries.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    LibraryListColumn(
                        library: library,
                        selectedEntryID: selectedEntry?.id,
                        select: { selectedEntryID = $0.id },
                        remove: { remove($0) }
                    )
                    .frame(width: 218)
                    Divider()
                    if let entry = selectedEntry {
                        ImageDetailView(
                            entry: entry,
                            library: library,
                            operationsDisabled: sendDisabled,
                            isEncoding: encodingEntryID == entry.id,
                            selectVariant: { library.selectVariant($0, for: entry) },
                            send: { send(entry, variant: $0) }
                        )
                    }
                }
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

    private func remove(_ entry: LibraryImage) {
        library.remove(entry)
        if selectedEntryID == entry.id {
            selectedEntryID = nil
        }
    }

    private func send(_ entry: LibraryImage, variant: QuantizedVariant) {
        guard !sendDisabled, encodingEntryID == nil else { return }
        guard let deviceID = UUID(uuidString: defaultDeviceID) else {
            processor.setErrorMessage("默认设备 ID 无效，请到“设备”页重新设置默认设备。")
            return
        }
        encodingEntryID = entry.id
        Task {
            defer { encodingEntryID = nil }
            do {
                guard let image = library.image(for: entry, file: .variant(variant)) else {
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

/// 左侧库列表：条目缩略图、名称、日期、已选变体徽标与删除入口。
private struct LibraryListColumn: View {
    @ObservedObject var library: ImageLibrary
    let selectedEntryID: UUID?
    let select: (LibraryImage) -> Void
    let remove: (LibraryImage) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(library.entries) { entry in
                    LibraryItemRow(
                        entry: entry,
                        thumbnail: thumbnail(for: entry),
                        selectedVariant: entry.selectedVariantID.flatMap(QuantizedVariant.implementedVariant(withID:)),
                        isSelected: entry.id == selectedEntryID,
                        remove: { remove(entry) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { select(entry) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text(entry.displayName))
                    .accessibilityValue(Text(
                        entry.selectedVariantID.flatMap(QuantizedVariant.implementedVariant(withID:))
                            .map { "已选 \($0.name)" } ?? "未选中"
                    ))
                    .accessibilityAction(.default) { select(entry) }
                    .accessibilityAction(named: Text("删除条目")) { remove(entry) }
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// 缩略图：条目已选变体的量化图（未选中时用标准量化）。
    private func thumbnail(for entry: LibraryImage) -> NSImage? {
        let variant = entry.selectedVariantID.flatMap(QuantizedVariant.implementedVariant(withID:))
            ?? QuantizedVariant.implementedVariant(withID: "plain")
        guard let variant else { return nil }
        return library.image(for: entry, file: .variant(variant))
    }
}

/// 库列表条目：2:3 量化缩略图 + 名称/日期/已选徽标，悬停或右键可删除。
private struct LibraryItemRow: View {
    let entry: LibraryImage
    let thumbnail: NSImage?
    let selectedVariant: QuantizedVariant?
    let isSelected: Bool
    let remove: () -> Void

    @State private var isHovering = false

    /// 列表日期格式：MM/DD HH:mm。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            thumbnailView
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.dateFormatter.string(from: entry.addedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let selectedVariant {
                    Text("已选 \(selectedVariant.name)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
            }

            Spacer(minLength: 0)

            if isHovering {
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("从图片库删除该条目")
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : (isHovering ? Color.primary.opacity(0.05) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(role: .destructive) {
                remove()
            } label: {
                Label("删除条目", systemImage: "trash")
            }
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
