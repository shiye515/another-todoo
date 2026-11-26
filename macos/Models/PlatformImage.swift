import CoreGraphics
import Foundation
import ImageIO

#if canImport(UIKit)
import UIKit
/// 跨平台位图别名（macOS: NSImage / iOS: UIImage）。
typealias PlatformImage = UIImage
#else
import AppKit
/// 跨平台位图别名（macOS: NSImage / iOS: UIImage）。
typealias PlatformImage = NSImage
#endif

/// 跨平台位图工具：CGImage 互转、文件解码与 PNG 写入（ImageIO）。
enum PlatformImageIO {
    /// CGImage → 平台位图。
    static func image(from cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    /// 平台位图 → CGImage。
    static func cgImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /// 从图片文件解码（ImageIO，任意平台）。
    static func image(contentsOf url: URL) -> PlatformImage? {
        guard let cgImage = cgImage(contentsOf: url) else { return nil }
        return image(from: cgImage)
    }

    /// 从图片文件解码为 CGImage（ImageIO，任意平台）。
    static func cgImage(contentsOf url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 写 PNG 文件（ImageIO，原子写入）。
    static func writePNG(_ cgImage: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw ImageProcessorError.renderFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessorError.renderFailed
        }
    }
}
