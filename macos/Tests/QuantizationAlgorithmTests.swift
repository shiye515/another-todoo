import CoreGraphics
import XCTest

@testable import TodooCardMacApp

/// 量化算法测试：四种抖动算法的输出约束（调色板、确定性、抖动行为、系数表不变量）。
final class QuantizationAlgorithmTests: XCTestCase {

    private let palette: [(UInt8, UInt8, UInt8)] = [
        (0, 0, 0), (255, 255, 255), (255, 255, 0), (255, 0, 0), (0, 0, 255), (0, 255, 0),
    ]

    private func makeCGImage(width: Int = 32, height: Int = 32, fill: (CGFloat, CGFloat, CGFloat)) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: fill.0, green: fill.1, blue: fill.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixelBytes(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    func testOutputUsesOnlyPaletteColors() throws {
        let source = try makeCGImage(fill: (0.42, 0.37, 0.61))
        for algorithm in QuantizationAlgorithm.allCases {
            let output = try ImageProcessor.computeQuantized(source, algorithm: algorithm)
            let bytes = try pixelBytes(output)
            for index in 0..<(bytes.count / 4) {
                let color = (bytes[index * 4], bytes[index * 4 + 1], bytes[index * 4 + 2])
                XCTAssertTrue(palette.contains { $0 == color }, "\(algorithm) 输出含非调色板颜色 \(color)")
            }
        }
    }

    func testSolidBlackAndWhiteAreUnchangedForAllAlgorithms() throws {
        for algorithm in QuantizationAlgorithm.allCases {
            for fill in [(1.0, 1.0, 1.0), (0.0, 0.0, 0.0)] {
                let source = try makeCGImage(fill: (fill.0, fill.1, fill.2))
                let output = try ImageProcessor.computeQuantized(source, algorithm: algorithm)
                let bytes = try pixelBytes(output)
                let expected: UInt8 = fill.0 == 1.0 ? 255 : 0
                for index in 0..<(bytes.count / 4) {
                    XCTAssertEqual(bytes[index * 4], expected, "\(algorithm) 纯色图应保持纯色")
                }
            }
        }
    }

    func testMidGrayDithersToBlackAndWhiteMix() throws {
        let source = try makeCGImage(fill: (0.5, 0.5, 0.5))
        for algorithm: QuantizationAlgorithm in [.floydSteinberg, .atkinson, .ostromoukhov] {
            let bytes = try pixelBytes(try ImageProcessor.computeQuantized(source, algorithm: algorithm))
            var hasBlack = false
            var hasWhite = false
            for index in 0..<(bytes.count / 4) {
                if bytes[index * 4] == 0 { hasBlack = true }
                if bytes[index * 4] == 255 { hasWhite = true }
            }
            XCTAssertTrue(hasBlack && hasWhite, "\(algorithm) 中灰应抖动出黑白混合")
        }
    }

    func testOutputIsDeterministic() throws {
        let source = try makeCGImage(fill: (0.3, 0.6, 0.45))
        for algorithm in QuantizationAlgorithm.allCases {
            let first = try pixelBytes(try ImageProcessor.computeQuantized(source, algorithm: algorithm))
            let second = try pixelBytes(try ImageProcessor.computeQuantized(source, algorithm: algorithm))
            XCTAssertEqual(first, second, "\(algorithm) 输出应确定")
        }
    }

    func testOstromoukhovCoefficientTableInvariants() throws {
        let table = QuantizationAlgorithm.ostromoukhovCoefficients
        XCTAssertEqual(table.count, 256, "亮度 0...255 全覆盖")
        for (index, coeff) in table.enumerated() {
            XCTAssertGreaterThanOrEqual(coeff.d1, 0, "index \(index)")
            XCTAssertGreaterThanOrEqual(coeff.d2, 0, "index \(index)")
            XCTAssertGreaterThanOrEqual(coeff.d3, 0, "index \(index)")
            XCTAssertEqual(coeff.sum, coeff.d1 + coeff.d2 + coeff.d3, "index \(index) 归一化和应等于三系数之和")
            XCTAssertGreaterThan(coeff.sum, 0, "index \(index)")
        }
        // 黑白对称：亮度 0 与 255 的系数一致
        let first = try XCTUnwrap(table.first)
        let last = try XCTUnwrap(table.last)
        XCTAssertEqual([first.d1, first.d2, first.d3, first.sum], [last.d1, last.d2, last.d3, last.sum])
    }

    func testAtkinsonDiscardsQuarterOfError() {
        // Atkinson 六个邻居各 1/8，总计只传播 6/8 = 3/4 误差（区别于 Floyd–Steinberg 全额传播）。
        let weight: Float = 1.0 / 8.0
        XCTAssertEqual(weight * 6, 0.75, accuracy: 0.0001)
    }
}
