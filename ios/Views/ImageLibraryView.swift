import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 图片页：图片库列表（资产管理）+ 入库（照片/文件导入 → 裁剪）。
/// 点击条目进入详情页（成品图 + 量化预览 + 发送）。
struct ImageLibraryView: View {
    @ObservedObject var processor: ImageProcessor
    @ObservedObject var library: ImageLibrary
    @ObservedObject var transferService: TodooCardTransferService

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isImportingFiles = false
    @State private var isShowingAddOptions = false
    @State private var isPickingPhotos = false

    var body: some View {
        NavigationStack {
            Group {
                if library.entries.isEmpty {
                    ContentUnavailableView {
                        Label("图片库为空", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("点击右上角“添加图片”，裁剪确认后图片将保存到这里，重启不会丢失。")
                    }
                } else {
                    entryList
                }
            }
            .navigationTitle("图片")
            .navigationDestination(for: UUID.self) { entryID in
                if let entry = library.entries.first(where: { $0.id == entryID }) {
                    ImageDetailView(
                        entryID: entry.id,
                        library: library,
                        processor: processor,
                        transferService: transferService
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingAddOptions = true
                    } label: {
                        Label("添加图片", systemImage: "plus")
                    }
                    .disabled(processor.isCropping || processor.isProcessingAdd)
                }
            }
            .confirmationDialog("添加图片", isPresented: $isShowingAddOptions, titleVisibility: .visible) {
                Button("从照片选择") {
                    isPickingPhotos = true
                }
                Button("从文件导入") {
                    isImportingFiles = true
                }
                Button("取消", role: .cancel) {}
            }
            .photosPicker(
                isPresented: $isPickingPhotos,
                selection: $photoItems,
                maxSelectionCount: 20,
                matching: .images
            )
            .fileImporter(
                isPresented: $isImportingFiles,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    importFiles(urls)
                }
            }
            .onChange(of: photoItems) { items in
                guard !items.isEmpty else { return }
                let picked = items
                photoItems = []
                importPhotos(picked)
            }
            .sheet(isPresented: Binding(
                get: { processor.isCropping },
                set: { presented in
                    if !presented {
                        processor.cancelCrop()
                    }
                }
            )) {
                CropSheetView(processor: processor)
                    .interactiveDismissDisabled()
            }
        }
        .overlay(alignment: .top) { errorBanner }
    }

    // MARK: - 列表

    private var entryList: some View {
        List {
            ForEach(library.entries) { entry in
                NavigationLink(value: entry.id) {
                    LibraryItemRow(
                        entry: entry,
                        thumbnail: thumbnail(for: entry)
                    )
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        library.remove(entry)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        library.remove(entry)
                    } label: {
                        Label("删除条目", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// 缩略图：条目已选变体的量化图（未选中时用标准量化）。
    private func thumbnail(for entry: LibraryImage) -> PlatformImage? {
        let variant = entry.selectedVariantID.flatMap(QuantizedVariant.implementedVariant(withID:))
            ?? QuantizedVariant.implementedVariant(withID: "plain")
        guard let variant else { return nil }
        return library.image(for: entry, file: .variant(variant))
    }

    private var errorBanner: some View {
        Group {
            if let message = library.lastError ?? processor.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - 导入

    /// 文件导入：复制进临时目录后再进入裁剪队列（避免安全作用域失效）。
    private func importFiles(_ urls: [URL]) {
        var copied: [URL] = []
        let temporary = FileManager.default.temporaryDirectory
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let target = temporary
                .appendingPathComponent("import-\(UUID().uuidString)")
                .appendingPathExtension(url.pathExtension.isEmpty ? "png" : url.pathExtension)
            do {
                try FileManager.default.copyItem(at: url, to: target)
                copied.append(target)
            } catch {
                processor.setErrorMessage("无法读取图片 \(url.lastPathComponent)，已跳过")
            }
        }
        processor.beginAdd(urls: copied)
    }

    /// 照片导入：写入临时文件后进入裁剪队列。
    private func importPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var urls: [URL] = []
            for item in items {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        let target = FileManager.default.temporaryDirectory
                            .appendingPathComponent("photo-\(UUID().uuidString).png")
                        try data.write(to: target)
                        urls.append(target)
                    }
                } catch {
                    await MainActor.run {
                        processor.setErrorMessage("读取照片失败：\(error.localizedDescription)")
                    }
                }
            }
            await MainActor.run {
                processor.beginAdd(urls: urls)
            }
        }
    }
}

/// 图片库列表行：2:3 量化缩略图 + 名称/日期/已选徽标。
private struct LibraryItemRow: View {
    let entry: LibraryImage
    let thumbnail: PlatformImage?

    /// 列表日期格式：MM/DD HH:mm。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    private var selectedVariant: QuantizedVariant? {
        entry.selectedVariantID.flatMap(QuantizedVariant.implementedVariant(withID:))
    }

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
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.dateFormatter.string(from: entry.addedAt))
                    .font(.system(size: 12))
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
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }
}
