import CoreGraphics
import Foundation
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

        // 每个条目目录包含成品 + 全部已实现变体量化图
        for entry in [first, second] {
            let fileNames = [ImageLibrary.ImageFile.processed.fileName]
                + QuantizedVariant.implemented.map(\.fileName)
            for fileName in fileNames {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: entryDirectory(entry).appendingPathComponent(fileName).path),
                    "缺少 \(fileName)"
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
        XCTAssertTrue(library.variantFilesMissing(entry))

        // 自愈补建
        let reloaded = makeLibrary()
        reloaded.loadFromDisk()
        await reloaded.regenerateMissingVariantImages()

        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDirectory(entry).appendingPathComponent("quantized.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDirectory(entry).appendingPathComponent("dithered.png").path))
        XCTAssertFalse(reloaded.variantFilesMissing(reloaded.entries[0]))
    }

    func testRequantizeOverwritesPersistedCopies() async throws {
        let library = makeLibrary()
        let entry = try await library.add(displayName: "A", processedCGImage: sampleCGImage(), configuration: .todooCard528x792)
        let quantizedURL = entryDirectory(entry).appendingPathComponent("quantized.png")

        let before = try Data(contentsOf: quantizedURL)
        try await library.requantizeAll(entry)
        let after = try Data(contentsOf: quantizedURL)

        XCTAssertEqual(before, after, "同输入重算应产生相同字节（确定性输出）")
        XCTAssertTrue(library.requantizingKeys.isEmpty)
    }

    func testRequantizeVariantOnlyOverwritesThatVariant() async throws {
        let library = makeLibrary()
        let entry = try await library.add(displayName: "A", processedCGImage: sampleCGImage(), configuration: .todooCard528x792)
        let quantizedURL = entryDirectory(entry).appendingPathComponent("quantized.png")
        let ditheredURL = entryDirectory(entry).appendingPathComponent("dithered.png")
        let junk = Data("junk".utf8)
        try junk.write(to: quantizedURL)
        try junk.write(to: ditheredURL)

        let plain = try XCTUnwrap(QuantizedVariant.implementedVariant(withID: "plain"))
        try await library.requantize(entry, variant: plain)

        XCTAssertNotEqual(try Data(contentsOf: quantizedURL), junk, "目标变体应被重算覆盖")
        XCTAssertEqual(try Data(contentsOf: ditheredURL), junk, "其余变体不应被改动")
        XCTAssertTrue(library.requantizingKeys.isEmpty)
    }

    func testRequantizeAllOverwritesAllVariants() async throws {
        let library = makeLibrary()
        let entry = try await library.add(displayName: "A", processedCGImage: sampleCGImage(), configuration: .todooCard528x792)
        let junk = Data("junk".utf8)
        for variant in QuantizedVariant.implemented {
            try junk.write(to: entryDirectory(entry).appendingPathComponent(variant.fileName))
        }

        try await library.requantizeAll(entry)

        for variant in QuantizedVariant.implemented {
            XCTAssertNotEqual(
                try Data(contentsOf: entryDirectory(entry).appendingPathComponent(variant.fileName)),
                junk,
                "\(variant.name) 应被重算覆盖"
            )
        }
    }

    func testMissingSingleVariantFileRegenerated() async throws {
        let library = makeLibrary()
        let entry = try await library.add(displayName: "A", processedCGImage: sampleCGImage(), configuration: .todooCard528x792)
        let quantizedURL = entryDirectory(entry).appendingPathComponent("quantized.png")
        let before = try Data(contentsOf: quantizedURL)
        try FileManager.default.removeItem(at: entryDirectory(entry).appendingPathComponent("dithered.png"))
        XCTAssertTrue(library.variantFilesMissing(entry))

        let reloaded = makeLibrary()
        reloaded.loadFromDisk()
        await reloaded.regenerateMissingVariantImages()

        XCTAssertFalse(reloaded.variantFilesMissing(reloaded.entries[0]))
        XCTAssertEqual(try Data(contentsOf: quantizedURL), before, "未缺失的变体不应被重算")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: entryDirectory(entry).appendingPathComponent("dithered.png").path),
            "缺失的变体应被补建"
        )
    }

    // MARK: - 变体选中持久化

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    private func writeManifestJSON(_ json: String) throws {
        try Data(json.utf8).write(to: manifestURL)
    }

    func testLegacyManifestWithoutSelectionDecodesUnselected() async throws {
        let library = makeLibrary()
        let entry = try await library.add(displayName: "A", processedCGImage: sampleCGImage(), configuration: .todooCard528x792)

        // 重写为旧格式 manifest（无 selectedVariantID 字段）
        try writeManifestJSON("""
        [{"id":"\(entry.id.uuidString)","displayName":"A","addedAt":"2026-11-25T10:00:00Z","configuration":{"targetWidth":528,"targetHeight":792,"rotationDegrees":0,"cropMode":"按目标比例","zoom":1,"horizontalOffset":0.5,"verticalOffset":0.5,"ditheringEnabled":true}}]
        """)

        let reloaded = makeLibrary()
        reloaded.loadFromDisk()

        XCTAssertEqual(reloaded.entries.count, 1, "旧格式 manifest 应正常解码")
        XCTAssertEqual(reloaded.entries.first?.displayName, "A")
        XCTAssertNil(reloaded.entries.first?.selectedVariantID, "缺省字段应视为未选中")
    }

    func testUnknownOrPlannedVariantSelectionClearedOnLoad() async throws {
        let library = makeLibrary()
        let entry = try await library.add(displayName: "A", processedCGImage: sampleCGImage(), configuration: .todooCard528x792)
        let base = """
        [{"id":"\(entry.id.uuidString)","displayName":"A","addedAt":"2026-11-25T10:00:00Z","selectedVariantID":"%@","configuration":{"targetWidth":528,"targetHeight":792,"rotationDegrees":0,"cropMode":"按目标比例","zoom":1,"horizontalOffset":0.5,"verticalOffset":0.5,"ditheringEnabled":true}}]
        """

        for invalidID in ["future-algo", "nope"] {
            try writeManifestJSON(base.replacingOccurrences(of: "%@", with: invalidID))
            let reloaded = makeLibrary()
            reloaded.loadFromDisk()
            XCTAssertEqual(reloaded.entries.count, 1)
            XCTAssertNil(reloaded.entries.first?.selectedVariantID, "\(invalidID) 不可选中，应视为未选中")
        }
    }

    func testVariantSelectionPersistsAcrossReload() async throws {
        let library = makeLibrary()
        let entry = try await library.add(displayName: "A", processedCGImage: sampleCGImage(), configuration: .todooCard528x792)
        let floyd = try XCTUnwrap(QuantizedVariant.implementedVariant(withID: "floyd"))
        // 规划中变体（自造样例）不可选中
        let planned = QuantizedVariant(
            id: "future-algo",
            name: "Future",
            subtitle: "",
            summary: "",
            isPlanned: true,
            fileName: "future.png",
            algorithm: .atkinson
        )

        library.selectVariant(planned, for: entry)
        XCTAssertNil(library.entries.first?.selectedVariantID)

        library.selectVariant(floyd, for: entry)
        XCTAssertEqual(library.entries.first?.selectedVariantID, "floyd")

        let reloaded = makeLibrary()
        reloaded.loadFromDisk()
        XCTAssertEqual(reloaded.entries.first?.selectedVariantID, "floyd", "重启后应恢复选中状态")

        // 清除选中同样持久化
        reloaded.selectVariant(nil, for: try XCTUnwrap(reloaded.entries.first))
        let again = makeLibrary()
        again.loadFromDisk()
        XCTAssertNil(again.entries.first?.selectedVariantID)
    }
}
