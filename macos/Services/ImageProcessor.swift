import CoreGraphics
import Foundation
import ImageIO
import os

/// 管理添加图片的裁剪队列与 payload 编码。
///
/// 图片页为纯列表布局：图片经“添加 → 裁剪确认”入库（仅存 528×792 成品，
/// 原图不保留），发送由列表条目的持久化量化图编码 payload。
@MainActor
final class ImageProcessor: ObservableObject {
    /// 裁剪画布的编辑配置（缩放/偏移/旋转），随裁剪确认一并入库。
    @Published var configuration = ImageEditConfiguration.todooCard528x792
    /// 裁剪画布显示的原图预览（仅添加队列期间驻留内存，不入库）。
    @Published private(set) var originalPreview: PlatformImage?
    /// 裁剪窗口是否可见（添加队列中有待裁剪图片）。
    @Published private(set) var isCropping = false
    /// 当前批次的渲染/入库在后台进行中。
    @Published private(set) var isProcessingAdd = false
    @Published private(set) var errorMessage: String?

    private let logger = Logger(subsystem: "com.todoo.TodooCardMacApp", category: "processor")
    /// 待裁剪的图片文件队列。
    private var pendingAddURLs: [URL] = []
    private var stagedSource: CGImage?
    private var stagedDisplayName = ""
    private weak var library: ImageLibrary?

    /// DetailPlaceholderView 装配时注入库服务。
    func attach(library: ImageLibrary) {
        self.library = library
    }

    func setErrorMessage(_ message: String) {
        errorMessage = message
    }

    // MARK: - 添加队列

    /// 开始一批添加：多选的图片 URL 依次进入裁剪窗口。
    func beginAdd(urls: [URL]) {
        guard library != nil else { return }
        guard pendingAddURLs.isEmpty, !isCropping, !isProcessingAdd else {
            setErrorMessage("上一批图片还在处理中，请稍候再添加。")
            return
        }
        guard !urls.isEmpty else { return }
        pendingAddURLs = urls
        advanceAddQueue()
    }

    /// 取出下一张待裁剪图片；无法读取的跳过并继续，队列空则结束。
    private func advanceAddQueue() {
        while !pendingAddURLs.isEmpty {
            let url = pendingAddURLs.removeFirst()
            do {
                guard let source = try Self.decodeImage(at: url) else {
                    throw ImageProcessorError.invalidImage
                }
                stagedSource = source
                stagedDisplayName = url.deletingPathExtension().lastPathComponent
                configuration = .todooCard528x792
                originalPreview = PlatformImageIO.image(from: source)
                isCropping = true
                return
            } catch {
                logger.error("跳过无法读取的图片：\(url.lastPathComponent, privacy: .public)")
                setErrorMessage("无法读取图片 \(url.lastPathComponent)，已跳过")
            }
        }
        isCropping = false
    }

    /// 确认裁剪：渲染 528×792 成品并入库，随后继续队列下一张。
    func confirmCrop() {
        guard isCropping, let source = stagedSource, let library else { return }
        let config = configuration
        let name = stagedDisplayName
        isCropping = false
        isProcessingAdd = true
        Task { [weak self] in
            await self?.processStagedAdd(
                source: source,
                configuration: config,
                displayName: name,
                library: library
            )
        }
    }

    private func processStagedAdd(
        source: CGImage,
        configuration config: ImageEditConfiguration,
        displayName name: String,
        library: ImageLibrary
    ) async {
        defer { isProcessingAdd = false }
        do {
            let processed = try Self.render(source, configuration: config)
            _ = try await library.add(
                displayName: name,
                processedCGImage: processed,
                configuration: config
            )
            logger.info("已入库：\(name, privacy: .public)")
        } catch {
            logger.error("入库失败：\(error.localizedDescription, privacy: .public)")
            setErrorMessage("入库失败：\(error.localizedDescription)")
        }
        advanceAddQueue()
    }

    /// 取消当前裁剪：该图片不入库，队列继续下一张。
    func cancelCrop() {
        guard isCropping else { return }
        logger.info("取消裁剪，跳过当前图片")
        stagedSource = nil
        stagedDisplayName = ""
        originalPreview = nil
        isCropping = false
        advanceAddQueue()
    }

    // MARK: - 裁剪编辑

    func updateCropConfiguration(_ configuration: ImageEditConfiguration) {
        self.configuration = configuration
    }

    func rotateRight() {
        configuration.rotationDegrees = (configuration.rotationDegrees + 90) % 360
        refreshStagedPreview()
    }

    func rotateLeft() {
        configuration.rotationDegrees = (configuration.rotationDegrees + 270) % 360
        refreshStagedPreview()
    }

    private func refreshStagedPreview() {
        guard let source = stagedSource else { return }
        do {
            let rotated = try Self.rotate(source, degrees: configuration.rotationDegrees)
            originalPreview = PlatformImageIO.image(from: rotated)
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    /// 按当前配置渲染裁剪成品预览（仅添加队列期间可用）。
    func renderedStagedPreview() -> PlatformImage? {
        guard let source = stagedSource else { return nil }
        guard let rendered = try? Self.render(source, configuration: configuration) else { return nil }
        return PlatformImageIO.image(from: rendered)
    }

    private static func decodeImage(at url: URL) throws -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }

    func makeControllerPayload(for image: PlatformImage) async throws -> Data {
        // 平台位图→CGImage 转换留在主线程，逐像素编码放后台执行。
        guard let cgImage = PlatformImageIO.cgImage(from: image) else {
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

    /// 按当前裁剪配置渲染成品效果（跨平台；iOS 裁剪画布的实时预览使用）。
    nonisolated static func render(_ source: CGImage, configuration: ImageEditConfiguration) throws -> CGImage {
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

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
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

    nonisolated private static func rotate(_ image: CGImage, degrees: Int) throws -> CGImage {
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

    nonisolated private static func rotateQuarter(_ image: CGImage, clockwise: Bool) throws -> CGImage {
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

    nonisolated private static func rotateHalf(_ image: CGImage) throws -> CGImage {
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

    /// 六色量化（可选误差扩散抖动）。纯像素计算，可在任意线程执行。
    nonisolated static func computeQuantized(_ image: CGImage, algorithm: QuantizationAlgorithm) throws -> CGImage {
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
            // Ostromoukhov 采用蛇形扫描（论文推荐），其余算法逐行扫描。
            let serpentine = algorithm == .ostromoukhov && y % 2 == 1
            for step in 0..<width {
                let x = serpentine ? width - 1 - step : step
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

                if algorithm != .none {
                    let errorRed = red - Float(selected.0)
                    let errorGreen = green - Float(selected.1)
                    let errorBlue = blue - Float(selected.2)
                    diffuseError(
                        algorithm,
                        &working,
                        width: width,
                        height: height,
                        x: x,
                        y: y,
                        red: errorRed,
                        green: errorGreen,
                        blue: errorBlue
                    )
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

    /// 按算法将量化误差扩散到未处理邻居。
    nonisolated private static func diffuseError(
        _ algorithm: QuantizationAlgorithm,
        _ working: inout [Float],
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        red: Float,
        green: Float,
        blue: Float
    ) {
        switch algorithm {
        case .none:
            break
        case .floydSteinberg:
            // 7/16 右，3/16 左下，5/16 下，1/16 右下。
            addError(&working, width: width, height: height, x: x + 1, y: y, red: red, green: green, blue: blue, weight: 7.0 / 16.0)
            addError(&working, width: width, height: height, x: x - 1, y: y + 1, red: red, green: green, blue: blue, weight: 3.0 / 16.0)
            addError(&working, width: width, height: height, x: x, y: y + 1, red: red, green: green, blue: blue, weight: 5.0 / 16.0)
            addError(&working, width: width, height: height, x: x + 1, y: y + 1, red: red, green: green, blue: blue, weight: 1.0 / 16.0)
        case .atkinson:
            // 六个邻居各 1/8，只传播 3/4 误差（丢弃 1/4，对比度更高）。
            let weight: Float = 1.0 / 8.0
            addError(&working, width: width, height: height, x: x + 1, y: y, red: red, green: green, blue: blue, weight: weight)
            addError(&working, width: width, height: height, x: x + 2, y: y, red: red, green: green, blue: blue, weight: weight)
            addError(&working, width: width, height: height, x: x - 1, y: y + 1, red: red, green: green, blue: blue, weight: weight)
            addError(&working, width: width, height: height, x: x, y: y + 1, red: red, green: green, blue: blue, weight: weight)
            addError(&working, width: width, height: height, x: x + 1, y: y + 1, red: red, green: green, blue: blue, weight: weight)
            addError(&working, width: width, height: height, x: x, y: y + 2, red: red, green: green, blue: blue, weight: weight)
        case .ostromoukhov:
            // 可变系数误差扩散：按当前亮度查表，蛇形扫描方向决定前向。
            let luma = 0.299 * red + 0.587 * green + 0.114 * blue
            let index = Int((min(max(luma, 0), 255) / 255.0 * 255.0).rounded())
            let (d1, d2, d3, sum) = QuantizationAlgorithm.ostromoukhovCoefficients[index]
            let total = Float(sum)
            let forward = Float(d1) / total
            let downBack = Float(d2) / total
            let down = Float(d3) / total
            let yIsReversedRow = y % 2 == 1 && height > 0 // 与扫描行方向一致
            let direction = (algorithm == .ostromoukhov && yIsReversedRow) ? -1 : 1
            addError(&working, width: width, height: height, x: x + direction, y: y, red: red, green: green, blue: blue, weight: forward)
            addError(&working, width: width, height: height, x: x - direction, y: y + 1, red: red, green: green, blue: blue, weight: downBack)
            addError(&working, width: width, height: height, x: x, y: y + 1, red: red, green: green, blue: blue, weight: down)
        }
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
