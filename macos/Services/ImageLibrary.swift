import AppKit
import Foundation
import os

/// 图片库：条目元数据与处理成果（裁剪成品 + 两个量化图）的持久化与内存缓存。
///
/// 存储布局：
/// `<libraryDirectory>/manifest.json`             条目元数据（原子写入）
/// `<libraryDirectory>/<UUID>/processed.png`      528×792 裁剪成品
/// `<libraryDirectory>/<UUID>/quantized.png`      无抖动量化图
/// `<libraryDirectory>/<UUID>/dithered.png`       Floyd–Steinberg 抖动量化图
@MainActor
final class ImageLibrary: NSObject, ObservableObject {
    enum ImageKind: String, CaseIterable {
        case processed, quantized, dithered

        var fileName: String { "\(rawValue).png" }
    }

    @Published private(set) var entries: [LibraryImage] = []
    /// 正在重新量化的条目 ID。
    @Published private(set) var requantizingIDs: Set<UUID> = []
    @Published private(set) var lastError: String?

    private let logger = Logger(subsystem: "com.todoo.TodooCardMacApp", category: "library")
    private let directory: URL
    private let manifestURL: URL
    private var imageCache: [Key: NSImage] = [:]
    private var loadCompleted = false

    private struct Key: Hashable {
        let id: UUID
        let kind: ImageKind
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
        Task { await regenerateMissingQuantizedImages() }
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
        let valid = loaded.filter { entry in
            FileManager.default.fileExists(atPath: processedURL(for: entry).path)
        }
        entries = valid
        if valid.count != loaded.count {
            logger.info("启动清理：移除 \(loaded.count - valid.count) 个成品缺失的条目")
            saveManifest()
        }
        logger.info("图片库加载完成：\(valid.count) 个条目")
    }

    /// 补建缺失的量化图（启动自愈，后台执行）。
    func regenerateMissingQuantizedImages() async {
        for entry in entries where quantizedFilesMissing(entry) {
            logger.info("补建量化图：\(entry.displayName, privacy: .public)")
            try? await requantize(entry)
        }
    }

    func quantizedFilesMissing(_ entry: LibraryImage) -> Bool {
        ImageKind.allCases.contains { kind in
            kind != .processed && !FileManager.default.fileExists(atPath: fileURL(for: entry, kind: kind).path)
        }
    }

    // MARK: - 增删

    /// 入库：写成品 PNG，即时生成并持久化两个量化图，追加条目。
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
        try writePNG(processedCGImage, to: entryDirectory.appendingPathComponent(ImageKind.processed.fileName))

        // 量化图即时生成，保证条目自包含（发送零等待）。
        let quantized = try ImageProcessor.computeQuantized(processedCGImage, dithering: false)
        let dithered = try ImageProcessor.computeQuantized(processedCGImage, dithering: true)
        try writePNG(quantized, to: entryDirectory.appendingPathComponent(ImageKind.quantized.fileName))
        try writePNG(dithered, to: entryDirectory.appendingPathComponent(ImageKind.dithered.fileName))

        entries.append(entry)
        saveManifest()
        imageCache[Key(id: entry.id, kind: .processed)] = NSImage(
            cgImage: processedCGImage,
            size: NSSize(width: processedCGImage.width, height: processedCGImage.height)
        )
        imageCache[Key(id: entry.id, kind: .quantized)] = NSImage(
            cgImage: quantized,
            size: NSSize(width: quantized.width, height: quantized.height)
        )
        imageCache[Key(id: entry.id, kind: .dithered)] = NSImage(
            cgImage: dithered,
            size: NSSize(width: dithered.width, height: dithered.height)
        )
        logger.info("入库：\(displayName, privacy: .public)（成品 + 量化图）")
        return entry
    }

    /// 删除条目：移除条目目录（成品 + 量化图）与元数据。
    func remove(_ entry: LibraryImage) {
        try? FileManager.default.removeItem(at: entryDirectory(for: entry))
        entries.removeAll { $0.id == entry.id }
        for kind in ImageKind.allCases {
            imageCache.removeValue(forKey: Key(id: entry.id, kind: kind))
        }
        saveManifest()
        logger.info("删除条目：\(entry.displayName, privacy: .public)")
    }

    // MARK: - 重新量化

    /// 从成品图重新生成两个量化图并覆盖持久化副本与内存缓存。
    /// 进行中的重新量化不可重复触发。
    func requantize(_ entry: LibraryImage) async throws {
        guard !requantizingIDs.contains(entry.id) else { return }
        requantizingIDs.insert(entry.id)
        defer { requantizingIDs.remove(entry.id) }
        do {
            let processed = try processedCGImage(for: entry)
            let quantized = try ImageProcessor.computeQuantized(processed, dithering: false)
            let dithered = try ImageProcessor.computeQuantized(processed, dithering: true)
            let entryDirectory = entryDirectory(for: entry)
            try writePNG(quantized, to: entryDirectory.appendingPathComponent(ImageKind.quantized.fileName))
            try writePNG(dithered, to: entryDirectory.appendingPathComponent(ImageKind.dithered.fileName))
            imageCache[Key(id: entry.id, kind: .quantized)] = NSImage(
            cgImage: quantized,
            size: NSSize(width: quantized.width, height: quantized.height)
        )
            imageCache[Key(id: entry.id, kind: .dithered)] = NSImage(
            cgImage: dithered,
            size: NSSize(width: dithered.width, height: dithered.height)
        )
            logger.info("重新量化完成：\(entry.displayName, privacy: .public)")
        } catch {
            lastError = "重新量化失败：\(error.localizedDescription)"
            logger.error("重新量化失败：\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - 图片访问

    /// 条目图片（缓存优先，未命中时同步解码并缓存）。
    func image(for entry: LibraryImage, kind: ImageKind) -> NSImage? {
        let key = Key(id: entry.id, kind: kind)
        if let cached = imageCache[key] { return cached }
        guard let image = NSImage(contentsOf: fileURL(for: entry, kind: kind)) else { return nil }
        imageCache[key] = image
        return image
    }

    // MARK: - 私有工具

    private func entryDirectory(for entry: LibraryImage) -> URL {
        directory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
    }

    private func fileURL(for entry: LibraryImage, kind: ImageKind) -> URL {
        entryDirectory(for: entry).appendingPathComponent(kind.fileName)
    }

    private func processedURL(for entry: LibraryImage) -> URL {
        fileURL(for: entry, kind: .processed)
    }

    private func processedCGImage(for entry: LibraryImage) throws -> CGImage {
        guard let image = NSImage(contentsOf: processedURL(for: entry)),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageProcessorError.renderFailed
        }
        return cgImage
    }

    private func writePNG(_ cgImage: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ImageProcessorError.renderFailed
        }
        try data.write(to: url, options: .atomic)
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
