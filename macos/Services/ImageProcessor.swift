import AppKit
import CoreGraphics
import Foundation
import ImageIO

@MainActor
final class ImageProcessor: ObservableObject {
    @Published var configuration = ImageEditConfiguration.todooCard528x792
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceSize: CGSize?
    @Published private(set) var originalPreview: NSImage?
    @Published private(set) var quantizedPreview: NSImage?
    @Published private(set) var floydSteinbergPreview: NSImage?
    @Published private(set) var processedImage: NSImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentStep: ImageProcessStep = .selection

    /// 量化预览的派发代次：连续触发（旋转/重置）时仅应用最新一次结果。
    private var previewGeneration = 0

    private var sourceImage: CGImage?

    func openImageSelection() {
        currentStep = .selection
        chooseImage()
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadImage(from: url)
    }

    func loadImage(from url: URL) {
        do {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ImageProcessorError.invalidImage
            }

            sourceURL = url
            sourceImage = image
            sourceSize = CGSize(width: image.width, height: image.height)
            originalPreview = NSImage(cgImage: image, size: .zero)
            errorMessage = nil
            quantizedPreview = nil
            floydSteinbergPreview = nil
            processedImage = nil
            currentStep = .cropping
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmCrop() {
        guard sourceImage != nil else { return }
        currentStep = .quantization
        refreshPreview()
    }

    func updateCropConfiguration(_ configuration: ImageEditConfiguration) {
        self.configuration = configuration
    }

    func refreshPreview() {
        guard let sourceImage else { return }
        guard currentStep == .quantization else { return }

        do {
            let finalImage = try render(sourceImage)
            processedImage = NSImage(cgImage: finalImage, size: NSSize(
                width: finalImage.width,
                height: finalImage.height
            ))

            // 量化是逐像素重计算，放到后台线程避免阻塞主线程。
            let dithering = configuration.ditheringEnabled
            previewGeneration += 1
            let generation = previewGeneration
            Task.detached(priority: .userInitiated) { [weak self] in
                async let quantized = Self.computeQuantized(finalImage, dithering: false)
                async let floydSteinberg = Self.computeQuantized(finalImage, dithering: dithering)
                do {
                    let images = try await (quantized, floydSteinberg)
                    await self?.applyQuantizedPreviews(images.0, floydSteinberg: images.1, generation: generation)
                } catch {
                    await self?.applyQuantizedError(error, generation: generation)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 量化结果派发代次校验：仅应用最新请求，防止旧结果覆盖新配置。
    private func applyQuantizedPreviews(
        _ quantized: CGImage,
        floydSteinberg: CGImage,
        generation: Int
    ) {
        guard previewGeneration == generation, currentStep == .quantization else { return }
        quantizedPreview = NSImage(cgImage: quantized, size: NSSize(
            width: quantized.width,
            height: quantized.height
        ))
        floydSteinbergPreview = NSImage(cgImage: floydSteinberg, size: NSSize(
            width: floydSteinberg.width,
            height: floydSteinberg.height
        ))
        errorMessage = nil
    }

    private func applyQuantizedError(_ error: Error, generation: Int) {
        guard previewGeneration == generation else { return }
        errorMessage = error.localizedDescription
    }

    func rotateRight() {
        configuration.rotationDegrees = (configuration.rotationDegrees + 90) % 360
        refreshOriginalPreviewForCrop()
        if currentStep == .quantization {
            refreshPreview()
        }
    }

    func rotateLeft() {
        configuration.rotationDegrees = (configuration.rotationDegrees + 270) % 360
        refreshOriginalPreviewForCrop()
        if currentStep == .quantization {
            refreshPreview()
        }
    }

    func refreshOriginalPreviewForCrop() {
        guard let sourceImage else { return }
        do {
            let rotated = try rotate(sourceImage, degrees: configuration.rotationDegrees)
            originalPreview = NSImage(cgImage: rotated, size: NSSize(
                width: rotated.width,
                height: rotated.height
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetEdits() {
        configuration = .todooCard528x792
        quantizedPreview = nil
        floydSteinbergPreview = nil
        processedImage = nil
        if currentStep == .quantization {
            refreshPreview()
        }
    }

    func cancelCrop() {
        configuration = .todooCard528x792
        quantizedPreview = nil
        floydSteinbergPreview = nil
        processedImage = nil
        currentStep = .selection
    }

    func saveProcessedImage(to url: URL) throws {
        guard let processedImage,
              let tiffData = processedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ImageProcessorError.renderFailed
        }
        try pngData.write(to: url)
    }

    func makeControllerPayload(for image: NSImage) async throws -> Data {
        // NSImage→CGImage 转换留在主线程，逐像素编码放后台执行。
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageProcessorError.renderFailed
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.encodeControllerPayload(cgImage: cgImage)
        }.value
    }

    /// 将 528×792 六色位图编码为控制器 payload（纯像素计算，可在任意线程执行）。
    nonisolated static func encodeControllerPayload(cgImage: CGImage) throws -> Data {
        guard cgImage.width == 528, cgImage.height == 792 else {
            throw ImageProcessorError.invalidTargetSize
        }

        guard let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageProcessorError.renderFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let rgba = context.makeImage(),
              let provider = rgba.dataProvider,
              let cfData = provider.data,
              let bytes = CFDataGetBytePtr(cfData) else {
            throw ImageProcessorError.renderFailed
        }

        let palette: [(UInt8, UInt8, UInt8, UInt8)] = [
            (0, 0, 0, 0),
            (255, 255, 255, 1),
            (255, 255, 0, 2),
            (255, 0, 0, 3),
            (0, 0, 255, 5),
            (0, 255, 0, 6)
        ]

        var codes = [UInt8](repeating: 1, count: cgImage.width * cgImage.height)
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width {
                let offset = (y * cgImage.width + x) * 4
                let red = Float(bytes[offset])
                let green = Float(bytes[offset + 1])
                let blue = Float(bytes[offset + 2])
                var selected = palette[1]
                var selectedDistance = Float.greatestFiniteMagnitude
                for color in palette {
                    let dr = red - Float(color.0)
                    let dg = green - Float(color.1)
                    let db = blue - Float(color.2)
                    let distance = dr * dr + dg * dg + db * db
                    if distance < selectedDistance {
                        selectedDistance = distance
                        selected = color
                    }
                }
                codes[y * cgImage.width + x] = selected.3
            }
        }

        var panelBitmap = [UInt8](repeating: 0, count: (codes.count + 1) / 2)
        for pixelIndex in 0..<codes.count {
            let byteIndex = pixelIndex / 2
            if pixelIndex.isMultiple(of: 2) {
                panelBitmap[byteIndex] = codes[pixelIndex] << 4
            } else {
                panelBitmap[byteIndex] |= codes[pixelIndex] & 0x0f
            }
        }

        let width = cgImage.width
        let height = cgImage.height
        func code(at pixelIndex: Int) -> UInt8 {
            let byte = panelBitmap[pixelIndex / 2]
            return pixelIndex.isMultiple(of: 2) ? byte >> 4 : byte & 0x0f
        }

        var calibrated = [UInt8](repeating: 0, count: panelBitmap.count)
        func setCode(_ code: UInt8, at pixelIndex: Int) {
            let byteIndex = pixelIndex / 2
            if pixelIndex.isMultiple(of: 2) {
                calibrated[byteIndex] = (calibrated[byteIndex] & 0x0f) | (code << 4)
            } else {
                calibrated[byteIndex] = (calibrated[byteIndex] & 0xf0) | (code & 0x0f)
            }
        }

        // 方向校准：与参考工具链 `todooCardCorrect` 一致（rotated180 + flippedHorizontally，
        // 合成等价于垂直翻转）。此前仅做 180° 旋转（缺少水平翻转），导致设备画面左右镜像。
        for sourceIndex in 0..<(width * height) {
            let sourceX = sourceIndex % width
            let sourceY = sourceIndex / width
            let destinationIndex = (height - 1 - sourceY) * width + sourceX
            setCode(code(at: sourceIndex), at: destinationIndex)
        }

        var controller = [UInt8](repeating: 0, count: panelBitmap.count)
        let destinationWidth = height
        for destinationIndex in 0..<(width * height) {
            let destinationX = destinationIndex % destinationWidth
            let destinationY = destinationIndex / destinationWidth
            let sourceX = width - 1 - destinationY
            let sourceY = height - 1 - destinationX
            let sourcePixelIndex = sourceY * width + sourceX
            let byte = calibrated[sourcePixelIndex / 2]
            let color = sourcePixelIndex.isMultiple(of: 2) ? byte >> 4 : byte & 0x0f
            let destinationByteIndex = destinationIndex / 2
            if destinationIndex.isMultiple(of: 2) {
                controller[destinationByteIndex] = color << 4
            } else {
                controller[destinationByteIndex] |= color & 0x0f
            }
        }
        return Data(controller)
    }

    func setErrorMessage(_ message: String) {
        errorMessage = message
    }

    private func render(_ source: CGImage) throws -> CGImage {
        guard configuration.targetWidth > 0, configuration.targetHeight > 0 else {
            throw ImageProcessorError.invalidTargetSize
        }

        let rotated = try rotate(source, degrees: configuration.rotationDegrees)
        let targetWidth = configuration.targetWidth
        let targetHeight = configuration.targetHeight
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageProcessorError.renderFailed
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.interpolationQuality = .high

        let cropRatio: CGFloat = 2.0 / 3.0
        var cropWidth: CGFloat
        var cropHeight: CGFloat

        let sourceWidth = CGFloat(rotated.width)
        let sourceHeight = CGFloat(rotated.height)
        let sourceRatio = sourceWidth / sourceHeight

        if sourceRatio > cropRatio {
            cropHeight = sourceHeight
            cropWidth = cropHeight * cropRatio
        } else {
            cropWidth = sourceWidth
            cropHeight = cropWidth / cropRatio
        }

        cropWidth /= CGFloat(configuration.zoom)
        cropHeight /= CGFloat(configuration.zoom)
        cropWidth = min(cropWidth, sourceWidth)
        cropHeight = min(cropHeight, sourceHeight)

        let centerX = CGFloat(configuration.horizontalOffset) * sourceWidth
        let centerY = (1 - CGFloat(configuration.verticalOffset)) * sourceHeight
        let cropX = max(0, min(sourceWidth - cropWidth, centerX - cropWidth / 2))
        let cropY = max(0, min(sourceHeight - cropHeight, centerY - cropHeight / 2))
        context.draw(rotated.cropping(to: CGRect(
            x: cropX,
            y: cropY,
            width: cropWidth,
            height: cropHeight
        )) ?? rotated, in: CGRect(
            x: 0,
            y: 0,
            width: targetWidth,
            height: targetHeight
        ))

        guard let result = context.makeImage() else {
            throw ImageProcessorError.renderFailed
        }
        return result
    }

    private func rotate(_ image: CGImage, degrees: Int) throws -> CGImage {
        switch degrees % 360 {
        case 0:
            return image
        case 90:
            return try rotateQuarter(image, clockwise: true)
        case 180:
            return try rotateHalf(image)
        case 270:
            return try rotateQuarter(image, clockwise: false)
        default:
            return image
        }
    }

    private func rotateQuarter(_ image: CGImage, clockwise: Bool) throws -> CGImage {
        let sourceWidth = image.width
        let sourceHeight = image.height
        let targetWidth = sourceHeight
        let targetHeight = sourceWidth
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageProcessorError.renderFailed
        }

        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(targetWidth) / 2, y: CGFloat(targetHeight) / 2)
        context.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        context.translateBy(x: -CGFloat(sourceWidth) / 2, y: -CGFloat(sourceHeight) / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))

        guard let result = context.makeImage() else {
            throw ImageProcessorError.renderFailed
        }
        return result
    }

    private func rotateHalf(_ image: CGImage) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageProcessorError.renderFailed
        }
        context.translateBy(x: CGFloat(image.width), y: CGFloat(image.height))
        context.rotate(by: .pi)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else {
            throw ImageProcessorError.renderFailed
        }
        return result
    }

    /// 六色量化（可选 Floyd–Steinberg 抖动）。纯像素计算，可在任意线程执行。
    nonisolated private static func computeQuantized(_ image: CGImage, dithering: Bool) throws -> CGImage {
        let width = image.width
        let height = image.height

        guard let sourceContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageProcessorError.renderFailed
        }
        sourceContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let sourceData = sourceContext.makeImage(),
              let dataProvider = sourceData.dataProvider,
              let cfData = dataProvider.data,
              let pixelPointer = CFDataGetBytePtr(cfData) else {
            throw ImageProcessorError.renderFailed
        }

        var working = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let offset = index * 4
            working[offset] = Float(pixelPointer[offset])
            working[offset + 1] = Float(pixelPointer[offset + 1])
            working[offset + 2] = Float(pixelPointer[offset + 2])
            working[offset + 3] = 255
        }

        let palette: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0),
            (255, 255, 255),
            (255, 255, 0),
            (255, 0, 0),
            (0, 0, 255),
            (0, 255, 0)
        ]

        var output = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let offset = index * 4
                let red = working[offset]
                let green = working[offset + 1]
                let blue = working[offset + 2]

                var selected = palette[1]
                var selectedDistance = Float.greatestFiniteMagnitude
                for color in palette {
                    let dr = red - Float(color.0)
                    let dg = green - Float(color.1)
                    let db = blue - Float(color.2)
                    let distance = dr * dr + dg * dg + db * db
                    if distance < selectedDistance {
                        selectedDistance = distance
                        selected = color
                    }
                }

                output[offset] = selected.0
                output[offset + 1] = selected.1
                output[offset + 2] = selected.2
                output[offset + 3] = 255

                if dithering {
                    let errorRed = red - Float(selected.0)
                    let errorGreen = green - Float(selected.1)
                    let errorBlue = blue - Float(selected.2)
                    addError(&working, width: width, height: height, x: x + 1, y: y, red: errorRed, green: errorGreen, blue: errorBlue, weight: 7.0 / 16.0)
                    addError(&working, width: width, height: height, x: x - 1, y: y + 1, red: errorRed, green: errorGreen, blue: errorBlue, weight: 3.0 / 16.0)
                    addError(&working, width: width, height: height, x: x, y: y + 1, red: errorRed, green: errorGreen, blue: errorBlue, weight: 5.0 / 16.0)
                    addError(&working, width: width, height: height, x: x + 1, y: y + 1, red: errorRed, green: errorGreen, blue: errorBlue, weight: 1.0 / 16.0)
                }
            }
        }

        guard let outputContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
              let outputBuffer = outputContext.data else {
            throw ImageProcessorError.renderFailed
        }
        memcpy(outputBuffer, output, output.count)
        guard let result = outputContext.makeImage() else {
            throw ImageProcessorError.renderFailed
        }
        return result
    }

    nonisolated private static func addError(
        _ working: inout [Float],
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        red: Float,
        green: Float,
        blue: Float,
        weight: Float
    ) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let offset = (y * width + x) * 4
        working[offset] += red * weight
        working[offset + 1] += green * weight
        working[offset + 2] += blue * weight
    }
}

enum ImageProcessorError: LocalizedError {
    case invalidImage
    case invalidTargetSize
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法读取所选图片"
        case .invalidTargetSize:
            return "目标像素必须大于 0"
        case .renderFailed:
            return "图片处理失败"
        }
    }
}
