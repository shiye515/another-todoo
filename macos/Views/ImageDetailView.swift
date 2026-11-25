import AppKit
import SwiftUI

/// 详情区：成品图卡片 + 量化变体卡片行（横向滚动）+ 底部操作栏。
/// 变体卡片由 `QuantizedVariant.registry` 数据驱动，点击卡片选中要发送的版本。
struct ImageDetailView: View {
    let entry: LibraryImage
    @ObservedObject var library: ImageLibrary
    /// 传输/编码任一进行中（防并发禁用）。
    let operationsDisabled: Bool
    let isEncoding: Bool
    let selectVariant: (QuantizedVariant?) -> Void
    let send: (QuantizedVariant) -> Void

    private var selectedVariant: QuantizedVariant? {
        entry.selectedVariantID.flatMap(QuantizedVariant.implementedVariant(withID:))
    }

    /// 该条目任一变体重算中。
    private var isRequantizingEntry: Bool {
        library.requantizingKeys.contains { $0.entryID == entry.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                detailHead
                detailSub
                previewRow
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 头部

    private var detailHead: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.displayName)
                .font(.system(size: 17, weight: .bold))
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

    private var previewRow: some View {
        HStack(alignment: .top, spacing: 8) {
            OriginalCard(image: library.image(for: entry, file: .processed))
            ScrollView(.horizontal) {
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
                                select: { selectVariant(variant) },
                                regenerate: { Task { try? await library.requantize(entry, variant: variant) } }
                            )
                        }
                    }
                }
                .background(HorizontalWheelScrollSupport())
            }
            .scrollIndicators(.visible)
        }
    }

    // MARK: - 底部操作栏

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                selectionInfo
                Spacer()
                if isRequantizingEntry {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("重新量化全部") {
                    Task { try? await library.requantizeAll(entry) }
                }
                .disabled(operationsDisabled || isRequantizingEntry)

                if isEncoding {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 96)
                } else {
                    Button("发送到设备") {
                        if let selectedVariant {
                            send(selectedVariant)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedVariant == nil || operationsDisabled)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var selectionInfo: some View {
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
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
    }

    private static func formatSize(_ bytes: Int) -> String {
        String(format: "%.1f KB", Double(bytes) / 1024)
    }
}

// MARK: - 卡片

private let cardWidth: CGFloat = 236

private func cardBackground() -> some View {
    RoundedRectangle(cornerRadius: 12)
        .fill(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
}

/// 成品图卡片：界面标注的「原图」即 528×792 裁剪成品（原图不保留）。
private struct OriginalCard: View {
    let image: NSImage?

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
    let image: NSImage?
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
                    .help("重新生成：从成品图重算「\(variant.name)」并覆盖持久化副本")
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text("\(variant.name) \(variant.subtitle)"))
        .accessibilityValue(Text(variant.summary))
        .accessibilityAction(.default) { select() }
        .accessibilityAction(named: Text("重新生成")) {
            if !operationsDisabled {
                regenerate()
            }
        }
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
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                Text("该算法在后续版本提供\n卡片由算法清单自动生成")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
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
                .foregroundStyle(Color(nsColor: .separatorColor))
        )
    }
}

/// 卡片内的预览图：量化图用最近邻放大呈现 e-paper 像素颗粒感。
private struct PreviewImage: View {
    let image: NSImage?
    let pixelated: Bool

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
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
