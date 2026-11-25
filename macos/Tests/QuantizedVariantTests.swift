import XCTest

@testable import TodooCardMacApp

/// 量化变体注册表测试：变体↔文件名/量化算法映射，planned 变体不进计算与持久化路径。
final class QuantizedVariantTests: XCTestCase {

    func testVariantFileAndAlgorithmMapping() {
        let plain = QuantizedVariant.implementedVariant(withID: "plain")
        XCTAssertEqual(plain?.fileName, "quantized.png")
        XCTAssertEqual(plain?.algorithm, QuantizationAlgorithm.none)

        let floyd = QuantizedVariant.implementedVariant(withID: "floyd")
        XCTAssertEqual(floyd?.fileName, "dithered.png")
        XCTAssertEqual(floyd?.algorithm, .floydSteinberg)

        let atkinson = QuantizedVariant.implementedVariant(withID: "atkinson")
        XCTAssertEqual(atkinson?.fileName, "atkinson.png")
        XCTAssertEqual(atkinson?.algorithm, .atkinson)

        let ostromoukhov = QuantizedVariant.implementedVariant(withID: "ostromoukhov")
        XCTAssertEqual(ostromoukhov?.fileName, "ostromoukhov.png")
        XCTAssertEqual(ostromoukhov?.algorithm, .ostromoukhov)
    }

    func testImplementedExcludesPlannedVariants() {
        XCTAssertEqual(QuantizedVariant.implemented, QuantizedVariant.registry.filter { !$0.isPlanned })
        XCTAssertFalse(QuantizedVariant.implemented.contains { $0.isPlanned }, "planned 变体不得进入已实现清单")
    }

    func testPlannedVariantNotInComputeOrPersistencePath() {
        // 未知 id 查不到已实现映射：不产出文件、不可选中
        XCTAssertNil(QuantizedVariant.implementedVariant(withID: "unknown"))
        // 已实现变体的文件名互不相同且均不为空
        let fileNames = QuantizedVariant.implemented.map(\.fileName)
        XCTAssertEqual(Set(fileNames).count, fileNames.count)
        XCTAssertTrue(fileNames.allSatisfy { !$0.isEmpty })
    }
}
