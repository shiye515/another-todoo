import SwiftUI

struct CropSheetView: View {
    @ObservedObject var processor: ImageProcessor
    @Binding var isInteracting: Bool
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
                CropCanvasView(
                    image: processor.originalPreview,
                    configuration: processor.configuration,
                    isInteracting: $isInteracting
                ) { configuration in
                    processor.updateCropConfiguration(configuration)
                }
                .frame(width: 480, height: 480)
                .background(Color(nsColor: .controlBackgroundColor))

                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("旋转与裁剪")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("固定取景比例：2:3")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button("向左旋转") {
                            processor.rotateLeft()
                            processor.updateCropConfiguration(processor.configuration)
                        }
                        Button("向右旋转") {
                            processor.rotateRight()
                            processor.updateCropConfiguration(processor.configuration)
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("缩放")
                                .font(.caption)
                        }
                        ImageSliderRow(
                            value: $processor.configuration.zoom,
                            range: 1...3,
                            step: 0.05
                        )
                    }
                    .frame(maxWidth: .infinity)

                    Spacer()

                    HStack(spacing: 8) {
                        Spacer()
                        Button("取消") {
                            processor.cancelCrop()
                            dismiss()
                        }
                        Button("确认裁剪") {
                            onConfirm()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(width: 188, height: 448, alignment: .topLeading)
                .padding(.top, 16)
                .padding(.horizontal, 16)
        }
        .frame(width: 700, height: 480)
    }
}

struct ImageSliderRow: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        CustomZoomSlider(value: $value, range: range, step: step)
    }
}

private struct CustomZoomSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        GeometryReader { geometry in
            let progress = (value - range.lowerBound) /
                (range.upperBound - range.lowerBound)
            let knobX = geometry.size.width * progress

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.30))
                    .frame(height: 2)
                    .frame(maxWidth: .infinity)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .position(x: knobX, y: geometry.size.height / 2)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let width = max(geometry.size.width, 1)
                        let raw = Double(gesture.location.x / width)
                        let normalized = min(1, max(0, raw))
                        var next = range.lowerBound +
                            (range.upperBound - range.lowerBound) * normalized
                        let stepCount = round(
                            (next - range.lowerBound) / step
                        )
                        next = range.lowerBound + stepCount * step
                        value = min(range.upperBound, max(range.lowerBound, next))
                    }
            )
            // 无障碍：VoiceOver 以可调节元素呈现，支持递增/递减操作。
            .accessibilityElement()
            .accessibilityLabel("缩放")
            .accessibilityValue("\(Int((value - range.lowerBound) / (range.upperBound - range.lowerBound) * 100))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    value = min(range.upperBound, value + step)
                case .decrement:
                    value = max(range.lowerBound, value - step)
                @unknown default:
                    break
                }
            }
        }
        .frame(height: 18)
    }
}
