import AppKit
import CoreGraphics
import XCTest

@testable import TodooCardMacApp

/// 控制器 payload 编码测试：六色调色板映射、半字节打包与 528×792 尺寸约束。
final class ControllerPayloadTests: XCTestCase {
    /// 生成指定尺寸的纯色测试图。
    private func solidImage(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        width: Int = 528,
        height: Int = 792
    ) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    func testRejectsWrongSize() throws {
        let small = try solidImage(red: 0, green: 0, blue: 0, width: 100, height: 100)
        XCTAssertThrowsError(try ImageProcessor.encodeControllerPayload(cgImage: small)) { error in
            XCTAssertEqual(error as? ImageProcessorError, .invalidTargetSize)
        }
    }

    /// 纯色图与重排无关：所有半字节都应等于该颜色的调色板编码。
    func testSolidColorsMapToPaletteCodes() throws {
        // (输入 RGB 0...1, 期望 4-bit 编码)
        let cases: [(CGFloat, CGFloat, CGFloat, UInt8)] = [
            (0, 0, 0, 0),           // 黑
            (1, 1, 1, 1),           // 白
            (1, 1, 0, 2),           // 黄
            (1, 0, 0, 3),           // 红
            (0, 0, 1, 5),           // 蓝
            (0, 1, 0, 6),           // 绿
        ]
        let expectedCount = 528 * 792 / 2

        for (red, green, blue, code) in cases {
            let payload = try ImageProcessor.encodeControllerPayload(
                cgImage: solidImage(red: red, green: green, blue: blue)
            )
            XCTAssertEqual(payload.count, expectedCount)

            for byte in payload {
                XCTAssertEqual(byte >> 4, code)
                XCTAssertEqual(byte & 0x0f, code)
            }
        }
    }

    /// 非调色板颜色（灰色）应映射到最近邻色：中灰更接近白色。
    func testGrayMapsToNearestPaletteColor() throws {
        let payload = try ImageProcessor.encodeControllerPayload(
            cgImage: solidImage(red: 0.55, green: 0.55, blue: 0.55)
        )
        for byte in payload {
            XCTAssertEqual(byte >> 4, 1) // 白
            XCTAssertEqual(byte & 0x0f, 1)
        }
    }
}
