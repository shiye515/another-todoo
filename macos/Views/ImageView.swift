import SwiftUI
import UniformTypeIdentifiers

struct ImageView: View {
    @ObservedObject var processor: ImageProcessor
    @ObservedObject var transferService: TodooCardTransferService
    @State private var showingCropSheet = false
    @State private var isCropCanvasInteracting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if processor.currentStep == .quantization {
                    QuantizationView(processor: processor)
                        .padding(.zero)
                } else {
                    errorView
                    stepContent
                        .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    processor.openImageSelection()
                } label: {
                    Label("选择图片", systemImage: "photo.badge.plus")
                }
            }
        }
        .onChange(of: processor.currentStep) { step in
            showingCropSheet = step == .cropping
        }
        .sheet(isPresented: $showingCropSheet) {
            CropSheetView(
                processor: processor,
                isInteracting: $isCropCanvasInteracting,
                onConfirm: {
                    showingCropSheet = false
                    processor.confirmCrop()
                }
            )
        }
    }

    @ViewBuilder
    private var errorView: some View {
        if let errorMessage = processor.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch processor.currentStep {
        case .selection:
            PlaceholderCard(title: "第 1 步：选择图片") {
                Text("请选择 JPEG、PNG、HEIC 或 TIFF 图片，随后进入旋转裁剪窗口。")
                    .foregroundStyle(.secondary)
            }
        case .cropping:
            PlaceholderCard(title: "第 2 步：旋转裁剪") {
                Text("取景窗口已打开。调整完成后点击“确认裁剪”。")
                    .foregroundStyle(.secondary)
            }
        case .quantization:
            QuantizationView(
                processor: processor,
                transferService: transferService
            )
        }
    }

    private func saveImage() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            (processor.sourceURL?.deletingPathExtension().lastPathComponent ?? "todoo-card") +
            "-528x792.png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try processor.saveProcessedImage(to: url)
        } catch {
            processor.setErrorMessage(error.localizedDescription)
        }
    }
}

private struct PlaceholderCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct QuantizationView: View {
    @ObservedObject var processor: ImageProcessor
    @ObservedObject var transferService: TodooCardTransferService
    @AppStorage("defaultTodooCardDeviceID") private var defaultDeviceID = ""

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            previewCard(title: "裁剪后的原图", image: processor.processedImage)
            previewCard(
                title: "量化图",
                image: processor.quantizedPreview,
                sendEnabled: true
            ) {
                sendQuantizedImage()
            }
            previewCard(
                title: "Floyd-Steinberg 算法处理图",
                image: processor.floydSteinbergPreview,
                sendEnabled: true
            ) {
                sendFloydSteinbergImage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewCard(
        title: String,
        image: NSImage?,
        sendEnabled: Bool = false,
        sendAction: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("正在处理…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
            }
            if sendEnabled {
                Button("发送到设备") {
                    sendAction?()
                }
                .disabled(image == nil || defaultDeviceID.isEmpty)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
