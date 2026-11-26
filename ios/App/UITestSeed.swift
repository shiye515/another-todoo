#if DEBUG
import Foundation

/// UI 测试接缝（仅 DEBUG）：
/// - `-UITestResetLibrary`：启动时清空图片库，保证测试相互独立
/// - `-UITestSeedAddImage <path>`：将指定图片送入「添加 → 裁剪」队列
/// 真实用户走照片/文件导入入口，不经过此接缝。
@MainActor
enum UITestSeed {
    static func run(processor: ImageProcessor, library: ImageLibrary) {
        let arguments = CommandLine.arguments

        if arguments.contains("-UITestResetLibrary") {
            try? FileManager.default.removeItem(at: library.directory)
            try? FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        }

        if let index = arguments.firstIndex(of: "-UITestSeedAddImage"),
           index + 1 < arguments.count {
            let url = URL(fileURLWithPath: arguments[index + 1])
            if FileManager.default.fileExists(atPath: url.path) {
                processor.beginAdd(urls: [url])
            }
        }
    }
}
#endif
