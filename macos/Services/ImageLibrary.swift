import CoreGraphics
import Foundation
import ImageIO
import os

/// 图片库：条目元数据与处理成果（裁剪成品 + 各量化变体图）的持久化与内存缓存。
///
/// 存储布局：
/// `<libraryDirectory>/manifest.json`             条目元数据（原子写入）
/// `<libraryDirectory>/<UUID>/processed.png`      528×792 裁剪成品
/// `<libraryDirectory>/<UUID>/<变体文件名>`        各量化变体图（文件名由 QuantizedVariant 注册表给出）
@MainActor
final class ImageLibrary: NSObject, ObservableObject {
    /// 条目目录内的持久化图片：裁剪成品图与量化变体图。
    enum ImageFile: Hashable {
        case processed
        case variant(QuantizedVariant)

        var fileName: String {
            switch self {
            case .processed: return "processed.png"
            case .variant(let variant): return variant.fileName
            }
        }
    }

    /// 重新量化进行中状态：条目 × 变体粒度。
    struct RequantizingKey: Hashable {
        let entryID: UUID
        let variantID: String
    }

    @Published private(set) var entries: [LibraryImage] = []
    /// 正在重新量化的（条目, 变体）组合。
    @Published private(set) var requantizingKeys: Set<RequantizingKey> = []
    @Published private(set) var lastError: String?

    private let logger = Logger(subsystem: "com.todoo.TodooCardMacApp", category: "library")
    /// 图片库根目录（内部可见，供 UI 测试接缝重置数据）。
    let directory: URL
    private let manifestURL: URL
    private var imageCache: [Key: PlatformImage] = [:]
    private var loadCompleted = false

    private struct Key: Hashable {
        let id: UUID
        let file: ImageFile
    }

    /// directory 传入自定义目录（单元测试）；默认使用 Application Support。
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodooCardMacApp/ImageLibrary", isDirectory: true)
        self.directory = base
        self.manifestURL = base.appendingPathComponent("manifest.json")
        super.init()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // MARK: - 加载

    /// 启动加载：读取 manifest，剔除成品缺失的条目并清理元数据；随后后台补建缺失的量化图。
    func loadOnLaunch() {
        guard !loadCompleted else { return }
        loadCompleted = true
        loadFromDisk()
        Task { await regenerateMissingVariantImages() }
    }

    func loadFromDisk() {
        imageCache.removeAll()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: manifestURL) else {
            logger.info("启动加载：manifest 不存在（首次运行）")
            entries = []
            return
        }
        guard let loaded = try? decoder.decode([LibraryImage].self, from: data) else {
            logger.error("启动加载：manifest 解码失败")
            entries = []
            return
        }
        var selectionNormalized = false
        let valid = loaded.compactMap { entry -> LibraryImage? in
            guard FileManager.default.fileExists(atPath: processedURL(for: entry).path) else { return nil }
            var entry = entry
            // 未知或规划中的变体 id 视为未选中（旧数据 / 未来变体降级）。
            if let id = entry.selectedVariantID, QuantizedVariant.implementedVariant(withID: id) == nil {
                entry.selectedVariantID = nil
                selectionNormalized = true
            }
            return entry
        }
        entries = valid
        if valid.count != loaded.count || selectionNormalized {
            logger.info("启动清理：移除 \(loaded.count - valid.count) 个成品缺失的条目")
            saveManifest()
        }
        logger.info("图片库加载完成：\(valid.count) 个条目")
    }

    /// 补建缺失的变体量化图（启动自愈，后台执行）。
    func regenerateMissingVariantImages() async {
        for entry in entries where variantFilesMissing(entry) {
            logger.info("补建量化图：\(entry.displayName, privacy: .public)")
            for variant in QuantizedVariant.implemented
            where !FileManager.default.fileExists(atPath: fileURL(for: entry, file: .variant(variant)).path) {
                try? await requantize(entry, variant: variant)
            }
        }
    }

    /// 缺失任一已实现变体的量化图。
    func variantFilesMissing(_ entry: LibraryImage) -> Bool {
        QuantizedVariant.implemented.contains { variant in
            !FileManager.default.fileExists(atPath: fileURL(for: entry, file: .variant(variant)).path)
        }
    }

    // MARK: - 增删

    /// 入库：写成品 PNG，即时生成并持久化全部已实现变体量化图，追加条目。
    @discardableResult
    func add(
        displayName: String,
        processedCGImage: CGImage,
        configuration: ImageEditConfiguration
    ) async throws -> LibraryImage {
        let entry = LibraryImage(
            id: UUID(),
            displayName: displayName,
            addedAt: Date(),
            configuration: configuration
        )
        let entryDirectory = entryDirectory(for: entry)
        try FileManager.default.createDirectory(at: entryDirectory, withIntermediateDirectories: true)
        try writePNG(processedCGImage, to: entryDirectory.appendingPathComponent(ImageFile.processed.fileName))

        // 量化图即时生成，保证条目自包含（发送零等待）。
        for variant in QuantizedVariant.implemented {
            let quantized = try ImageProcessor.computeQuantized(processedCGImage, algorithm: variant.algorithm)
            try writePNG(quantized, to: entryDirectory.appendingPathComponent(variant.fileName))
            imageCache[Key(id: entry.id, file: .variant(variant))] = PlatformImageIO.image(from: quantized)
        }

        entries.append(entry)
        saveManifest()
        imageCache[Key(id: entry.id, file: .processed)] = PlatformImageIO.image(from: processedCGImage)
        logger.info("入库：\(displayName, privacy: .public)（成品 + 量化图）")
        return entry
    }

    /// 删除条目：移除条目目录（成品 + 量化图）与元数据。
    func remove(_ entry: LibraryImage) {
        try? FileManager.default.removeItem(at: entryDirectory(for: entry))
        entries.removeAll { $0.id == entry.id }
        imageCache = imageCache.filter { $0.key.id != entry.id }
        saveManifest()
        logger.info("删除条目：\(entry.displayName, privacy: .public)")
    }

    // MARK: - 变体选中

    /// 设置条目当前选中的量化变体（底部统一发送的版本）并持久化到 manifest。
    /// 仅接受已实现变体（规划中变体不可选中）；传 nil 清除选中。
    func selectVariant(_ variant: QuantizedVariant?, for entry: LibraryImage) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let variantID = variant.flatMap { $0.isPlanned ? nil : $0.id }
        guard entries[index].selectedVariantID != variantID else { return }
        entries[index].selectedVariantID = variantID
        saveManifest()
    }

    // MARK: - 重新量化

    /// 从成品图重新生成指定变体的量化图并覆盖持久化副本与内存缓存。
    /// 同一（条目, 变体）的重新量化不可重复触发；规划中变体不参与重算。
    func requantize(_ entry: LibraryImage, variant: QuantizedVariant) async throws {
        let key = RequantizingKey(entryID: entry.id, variantID: variant.id)
        guard !variant.isPlanned, !requantizingKeys.contains(key) else { return }
        requantizingKeys.insert(key)
        defer { requantizingKeys.remove(key) }
        do {
            let processed = try processedCGImage(for: entry)
            let quantized = try ImageProcessor.computeQuantized(processed, algorithm: variant.algorithm)
            try writePNG(quantized, to: entryDirectory(for: entry).appendingPathComponent(variant.fileName))
            imageCache[Key(id: entry.id, file: .variant(variant))] = PlatformImageIO.image(from: quantized)
            logger.info("重新量化完成：\(entry.displayName, privacy: .public) / \(variant.name, privacy: .public)")
        } catch {
            lastError = "重新量化失败：\(error.localizedDescription)"
            logger.error("重新量化失败：\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// 从成品图依次重算全部已实现变体并覆盖持久化副本（「重新量化全部」）。
    func requantizeAll(_ entry: LibraryImage) async throws {
        for variant in QuantizedVariant.implemented {
            try await requantize(entry, variant: variant)
        }
    }

    // MARK: - 图片访问

    /// 条目图片（缓存优先，未命中时同步解码并缓存）。
    func image(for entry: LibraryImage, file: ImageFile) -> PlatformImage? {
        let key = Key(id: entry.id, file: file)
        if let cached = imageCache[key] { return cached }
        guard let image = PlatformImageIO.image(contentsOf: fileURL(for: entry, file: file)) else { return nil }
        imageCache[key] = image
        return image
    }

    /// 变体量化图的文件大小与修改时间（详情区底部操作栏的选中信息）。
    func variantFileInfo(for entry: LibraryImage, variant: QuantizedVariant) -> (size: Int, modified: Date)? {
        let url = fileURL(for: entry, file: .variant(variant))
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return (size, modified)
    }

    // MARK: - 私有工具

    private func entryDirectory(for entry: LibraryImage) -> URL {
        directory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
    }

    private func fileURL(for entry: LibraryImage, file: ImageFile) -> URL {
        entryDirectory(for: entry).appendingPathComponent(file.fileName)
    }

    private func processedURL(for entry: LibraryImage) -> URL {
        fileURL(for: entry, file: .processed)
    }

    private func processedCGImage(for entry: LibraryImage) throws -> CGImage {
        guard let cgImage = PlatformImageIO.cgImage(contentsOf: processedURL(for: entry)) else {
            throw ImageProcessorError.renderFailed
        }
        return cgImage
    }

    private func writePNG(_ cgImage: CGImage, to url: URL) throws {
        try PlatformImageIO.writePNG(cgImage, to: url)
    }

    private func saveManifest() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(entries)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            logger.error("manifest 写入失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
