import SwiftUI

/// 裁剪页：拖拽平移 + 双指/滑杆缩放 + 旋转，实时预览 528×792 成品效果。
/// 确认后渲染成品入库（不保留原图）；取消跳过该图，队列继续下一张。
struct CropSheetView: View {
    @ObservedObject var processor: ImageProcessor

    @State private var preview: PlatformImage?
    @State private var baseZoom: Double = 1
    @State private var baseOffset: CGSize = .zero
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                previewCanvas
                Text("固定取景比例：2:3 · 确认裁剪后入库（不保留原图）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                controls
            }
            .padding()
            .navigationTitle("旋转与裁剪")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        processor.cancelCrop()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认裁剪") {
                        processor.confirmCrop()
                    }
                    .disabled(processor.isProcessingAdd)
                }
            }
        }
        .onAppear {
            baseZoom = processor.configuration.zoom
            baseOffset = CGSize(
                width: processor.configuration.horizontalOffset,
                height: processor.configuration.verticalOffset
            )
            refreshPreview()
        }
        .onDisappear {
            refreshTask?.cancel()
        }
    }

    // MARK: - 预览画布（拖拽平移 + 双指缩放）

    private var previewCanvas: some View {
        GeometryReader { geometry in
            ZStack {
                Color(.secondarySystemBackground)
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let width = max(geometry.size.width, 1)
                        let height = max(geometry.size.height, 1)
                        processor.configuration.horizontalOffset = clamped01(
                            baseOffset.width - Double(value.translation.width / width)
                        )
                        processor.configuration.verticalOffset = clamped01(
                            baseOffset.height + Double(value.translation.height / height)
                        )
                        scheduleRefresh()
                    }
                    .onEnded { _ in
                        baseOffset = CGSize(
                            width: processor.configuration.horizontalOffset,
                            height: processor.configuration.verticalOffset
                        )
                        refreshPreview()
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        processor.configuration.zoom = min(3, max(1, baseZoom * Double(scale)))
                        scheduleRefresh()
                    }
                    .onEnded { scale in
                        baseZoom = min(3, max(1, baseZoom * Double(scale)))
                        refreshPreview()
                    }
            )
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 控件

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    processor.rotateLeft()
                    syncRotation()
                } label: {
                    Label("向左旋转", systemImage: "rotate.left")
                }
                Button {
                    processor.rotateRight()
                    syncRotation()
                } label: {
                    Label("向右旋转", systemImage: "rotate.right")
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Text("缩放")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { processor.configuration.zoom },
                        set: { value in
                            processor.configuration.zoom = value
                            baseZoom = value
                            scheduleRefresh()
                        }
                    ),
                    in: 1...3
                )
                Text(String(format: "%.2f×", processor.configuration.zoom))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }

            Button("确认裁剪") {
                processor.confirmCrop()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(processor.isProcessingAdd)
        }
    }

    // MARK: - 预览刷新

    /// 旋转按钮：保持本地手势基线与配置一致并刷新预览。
    private func syncRotation() {
        baseZoom = processor.configuration.zoom
        refreshPreview()
    }

    /// 手势高频变化时合并刷新（约 30fps），避免逐帧全量渲染。
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else { return }
            refreshPreview()
        }
    }

    private func refreshPreview() {
        preview = processor.renderedStagedPreview()
    }

    private func clamped01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
