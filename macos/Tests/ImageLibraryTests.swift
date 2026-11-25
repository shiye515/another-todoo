import AppKit
import CoreGraphics
import XCTest

@testable import TodooCardMacApp

/// 图片库服务测试：使用临时目录注入，覆盖添加/删除/持久化/自愈。
@MainActor
final class ImageLibraryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageLibraryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLibrary() -> ImageLibrary {
        ImageLibrary(directory: directory)
    }

    private func sampleCGImage(red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return try XCTUnwrap(context.makeImage())
    }

    private func entryDirectory(_ entry: LibraryImage) -> URL {
        directory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
    }

    func testAddMultipleEntriesNoOverwrite() async throws {
        let library = makeLibrary()
        let first = try await library.add(
            displayName: "A",
            processedCGImage: sampleCGImage(),
            configuration: .todooCard528x792
        )
        let second = try await library.add(
            displayName: "B",
            processedCGImage: sampleCGImage(red: 1, green: 1, blue: 1),
            configuration: .todooCard528x792
        )
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(library.entries.count, 2)
        XCTAssertEqual(library.entries.map(\.displayName), ["A", "B"])

        // 每个条目目录包含成品 + 两个量化图
        for entry in [first, second] {
            for kind in ImageLibrary.ImageKind.allCases {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: entryDirectory(entry).appendingPathComponent(kind.fileName).path),
                    "缺少 \(kind.fileName)"
                )
            }
        }
    }

    func testRemoveOnlyTargetEntry() async throws {
        let library = makeLibrary()
        let first = try await library.add(displayName: "A", processedCGImage: sampleCGImage(), configuration: .todooCard528x792)
        let second = try await library.add(
            displayName: "B",
            processedCGImage: sampleCGImage(red: 1, green: 1, blue: 1),
            configuration: .todooCard528x792
        )

        library.remove(first)

        XCTAssertEqual(library.entries.map(\.id), [second.id])
        // 目标条目目录被清理，其他条目不受影响
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryDirectory(first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDirectory(second).path))
    }

    func testReloadPersistsEntries() async throws {
        let library = makeLibrary()
        let added = try await library.add(displayName: "A", processedCGImage: sampleCGImage(), configuration: .todooCard528x792)

        // 模拟重启：同目录的新实例
        let reloaded = makeLibrary()
        reloaded.loadFromDisk()

        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.id, added.id)
        XCTAssertEqual(reloaded.entries.first?.displayName, "A")
        XCTAssertEqual(reloaded.entries.first?.configuration, .todooCard528x792)
    }

    func testMissingProcessedDropsEntryAndCleansManifest() async throws {
        let library = makeLibrary()
        let entry = try await library.add(displayName: "A", processedCGImage: sampleCGImage(), configuration: .todooCard528x792)

        // 手动删除成品文件
        try FileManager.default.removeItem(at: entryDirectory(entry).appendingPathComponent("processed.png"))

        let reloaded = makeLibrary()
        reloaded.loadFromDisk()
        XCTAssertEqual(reloaded.entries.count, 0, "成品缺失的条目不应恢复")

        // manifest 已清理：再次加载仍为空
        let again = makeLibrary()
        again.loadFromDisk()
        XCTAssertEqual(again.entries.count, 0)
    }

    func testMissingQuantizedRegenerated() async throws {
        let library = makeLibrary()
        let entry = try await library.add(displayName: "A", processedCGImage: sampleCGImage(), configuration: .todooCard528x792)

        // 删除两个量化图
        try FileManager.default.removeItem(at: entryDirectory(entry).appendingPathComponent("quantized.png"))
        try FileManager.default.removeItem(at: entryDirectory(entry).appendingPathComponent("dithered.png"))
        XCTAssertTrue(library.quantizedFilesMissing(entry))

        // 自愈补建
        let reloaded = makeLibrary()
        reloaded.loadFromDisk()
        await reloaded.regenerateMissingQuantizedImages()

        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDirectory(entry).appendingPathComponent("quantized.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDirectory(entry).appendingPathComponent("dithered.png").path))
        XCTAssertFalse(reloaded.quantizedFilesMissing(reloaded.entries[0]))
    }

    func testRequantizeOverwritesPersistedCopies() async throws {
        let library = makeLibrary()
        let entry = try await library.add(displayName: "A", processedCGImage: sampleCGImage(), configuration: .todooCard528x792)
        let quantizedURL = entryDirectory(entry).appendingPathComponent("quantized.png")

        let before = try Data(contentsOf: quantizedURL)
        try await library.requantize(entry)
        let after = try Data(contentsOf: quantizedURL)

        XCTAssertEqual(before, after, "同输入重算应产生相同字节（确定性输出）")
        XCTAssertFalse(library.requantizingIDs.contains(entry.id))
    }
}
