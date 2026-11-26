import SwiftUI

/// 待发送到设备的一次传输任务（驱动 `.sheet(item:)` 呈现进度弹窗）。
private struct PendingTransfer: Identifiable {
    let id = UUID()
    let payload: Data
    let deviceID: UUID
}

/// 详情页：成品图卡片 + 量化变体卡片行（横向滚动）+ 底部操作栏。
/// 变体卡片由 `QuantizedVariant.registry` 数据驱动，点击卡片选中要发送的版本。
struct ImageDetailView: View {
    let entryID: UUID
    @ObservedObject var library: ImageLibrary
    @ObservedObject var processor: ImageProcessor
    @ObservedObject var transferService: TodooCardTransferService

    @AppStorage("defaultTodooCardDeviceID") private var defaultDeviceID = ""
    @State private var pendingTransfer: PendingTransfer?
    @State private var encodingEntryID: UUID?

    private var entry: LibraryImage? {
        library.entries.first { $0.id == entryID }
    }

    private var selectedVariant: QuantizedVariant? {
        entry?.selectedVariantID.flatMap(QuantizedVariant.implementedVariant(withID:))
    }

    /// 传输/编码任一进行中（防并发禁用）。
    private var operationsDisabled: Bool {
        pendingTransfer != nil || transferService.isTransferActive || encodingEntryID != nil
    }

    /// 该条目任一变体重算中。
    private var isRequantizingEntry: Bool {
        library.requantizingKeys.contains { $0.entryID == entryID }
    }

    var body: some View {
        Group {
            if let entry {
                content(for: entry)
            } else {
                ContentUnavailableView("条目不存在", systemImage: "photo")
            }
        }
        .navigationTitle(entry?.displayName ?? "详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pendingTransfer) { transfer in
            TransferProgressSheet(
                transferService: transferService,
                controllerPayload: transfer.payload,
                deviceID: transfer.deviceID
            )
        }
    }

    private func content(for entry: LibraryImage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                detailHead(entry)
                detailSub
                previewRow(entry)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(entry) }
    }

    // MARK: - 头部

    private func detailHead(_ entry: LibraryImage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.displayName)
                .font(.system(size: 20, weight: .bold))
            Text("添加于 \(entry.addedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var detailSub: some View {
        Text("成品图与全部量化预览 · 点击量化卡片选中要发送的版本 · 点击「重新生成」可从成品图重算")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .padding(.bottom, 14)
    }

    // MARK: - 预览行

    private func previewRow(_ entry: LibraryImage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            OriginalCard(image: library.image(for: entry, file: .processed))
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(QuantizedVariant.registry) { variant in
                        if variant.isPlanned {
                            PlannedVariantCard(variant: variant)
                        } else {
                            VariantCard(
                                variant: variant,
                                image: library.image(for: entry, file: .variant(variant)),
                                isSelected: variant.id == entry.selectedVariantID,
                                isRequantizing: library.requantizingKeys.contains(
                                    ImageLibrary.RequantizingKey(entryID: entry.id, variantID: variant.id)
                                ),
                                operationsDisabled: operationsDisabled,
                                select: {
                                    library.selectVariant(variant, for: entry)
                                },
                                regenerate: {
                                    Task { try? await library.requantize(entry, variant: variant) }
                                }
                            )
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("variantsRow")
        }
    }

    // MARK: - 底部操作栏

    private func actionBar(_ entry: LibraryImage) -> some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                selectionInfo(entry)
                HStack(spacing: 12) {
                    if isRequantizingEntry {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("重新量化全部") {
                        Task { try? await library.requantizeAll(entry) }
                    }
                    .disabled(operationsDisabled || isRequantizingEntry)

                    Spacer()

                    if encodingEntryID != nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("发送到设备") {
                            if let selectedVariant {
                                send(entry, variant: selectedVariant)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedVariant == nil || operationsDisabled)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func selectionInfo(_ entry: LibraryImage) -> some View {
        if let selectedVariant {
            let info = library.variantFileInfo(for: entry, variant: selectedVariant)
            (
                Text("当前选择：")
                    + Text("\(selectedVariant.name)（\(selectedVariant.subtitle)）").bold()
                    + Text(info.map { " · \(Self.formatSize($0.size)) · 量化于 \($0.modified.formatted(date: .omitted, time: .shortened))" } ?? "")
            )
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
        } else {
            Text("尚未选择量化版本 —— 点击上方任意量化卡片")
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
        }
    }

    private static func formatSize(_ bytes: Int) -> String {
        String(format: "%.1f KB", Double(bytes) / 1024)
    }

    // MARK: - 发送

    private func send(_ entry: LibraryImage, variant: QuantizedVariant) {
        guard !operationsDisabled else { return }
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

// MARK: - 卡片

private let cardWidth: CGFloat = 236

private func cardBackground() -> some View {
    RoundedRectangle(cornerRadius: 12)
        .fill(Color(.secondarySystemGroupedBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
}

/// 成品图卡片：界面标注的「原图」即 528×792 裁剪成品（原图不保留）。
private struct OriginalCard: View {
    let image: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewImage(image: image, pixelated: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("原图（裁剪成品）")
                    .font(.system(size: 12, weight: .semibold))
                Text("528×792 · 仅保留裁剪成品")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .padding(10)
        .frame(width: cardWidth, alignment: .topLeading)
        .background(cardBackground())
    }
}

/// 量化变体卡片：点击选中，右上「重新生成」从成品图重算该变体。
private struct VariantCard: View {
    let variant: QuantizedVariant
    let image: PlatformImage?
    let isSelected: Bool
    let isRequantizing: Bool
    let operationsDisabled: Bool
    let select: () -> Void
    let regenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                PreviewImage(image: image, pixelated: true)
                if isSelected {
                    Text("已选中")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .padding(8)
                }
            }
            HStack(spacing: 6) {
                Text(variant.name)
                    .font(.system(size: 12.5, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if isRequantizing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: regenerate) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("重新生成 \(variant.name)")
                    .disabled(operationsDisabled)
                }
            }
            .padding(.top, 8)
            Text(variant.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(10)
        .frame(width: cardWidth, alignment: .topLeading)
        .background(cardBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { select() }
    }
}

/// 规划中算法的占位卡：不可交互，不参与计算、持久化与发送。
private struct PlannedVariantCard: View {
    let variant: QuantizedVariant

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color(.tertiaryLabel))
                Text("该算法在后续版本提供\n卡片由算法清单自动生成")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .frame(height: 324)
            Text(variant.name)
                .font(.system(size: 12.5, weight: .bold))
                .padding(.top, 8)
        }
        .padding(10)
        .frame(width: cardWidth, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .foregroundStyle(Color(.separator))
        )
    }
}

/// 卡片内的预览图：量化图用最近邻放大呈现 e-paper 像素颗粒感。
private struct PreviewImage: View {
    let image: PlatformImage?
    let pixelated: Bool

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(pixelated ? .none : .high)
                    .scaledToFit()
            } else {
                ZStack {
                    Color.primary.opacity(0.04)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(528.0 / 792.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
