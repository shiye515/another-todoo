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

    /// 方向管线回归：非对称图案下，编码输出必须与参考工具链
    /// `todooCardCorrect`（垂直翻转 + SE0368 控制器重排）逐字节一致。
    /// 此前实现缺少水平翻转导致设备画面左右镜像。
    func testMatchesReferenceOrientationPipeline() throws {
        let width = 528
        let height = 792
        let palette: [(UInt8, UInt8, UInt8, UInt8)] = [
            (0, 0, 0, 0), (255, 255, 255, 1), (255, 255, 0, 2),
            (255, 0, 0, 3), (0, 0, 255, 5), (0, 255, 0, 6)
        ]

        // 确定性非对称调色板图案（精确落在调色板上，最近邻量化为恒等映射）。
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var codes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, code) = palette[(x * 7 + y * 13) % 6]
                let offset = (y * width + x) * 4
                rgba[offset] = r
                rgba[offset + 1] = g
                rgba[offset + 2] = b
                rgba[offset + 3] = 255
                codes[y * width + x] = code
            }
        }
        let context = try XCTUnwrap(CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())

        let payload = try ImageProcessor.encodeControllerPayload(cgImage: image)
        XCTAssertEqual(payload.count, width * height / 2)

        // 参考 oracle：controller(dx, dy) = codes(dx, width-1-dy)（dx 为输出行 0..<height，
        // dy 为输出列 0..<width），半字节顺序与实现一致（偶数像素高 4 位）。
        var expected = [UInt8](repeating: 0, count: width * height / 2)
        func setCode(_ code: UInt8, at pixelIndex: Int) {
            let byteIndex = pixelIndex / 2
            if pixelIndex.isMultiple(of: 2) {
                expected[byteIndex] = (expected[byteIndex] & 0x0f) | (code << 4)
            } else {
                expected[byteIndex] = (expected[byteIndex] & 0xf0) | (code & 0x0f)
            }
        }
        for destinationIndex in 0..<(width * height) {
            let destinationX = destinationIndex % height
            let destinationY = destinationIndex / height
            let code = codes[destinationX * width + (width - 1 - destinationY)]
            setCode(code, at: destinationIndex)
        }

        XCTAssertEqual(payload, Data(expected))
    }
}
