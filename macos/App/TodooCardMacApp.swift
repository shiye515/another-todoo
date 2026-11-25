import SwiftUI

@main
struct TodooCardMacApp: App {
    /// 窗口最小尺寸，同时作为启动时的默认尺寸。
    static let minWindowWidth: CGFloat = 900
    static let minWindowHeight: CGFloat = 560

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: Self.minWindowWidth, minHeight: Self.minWindowHeight)
        }
        .defaultSize(width: Self.minWindowWidth, height: Self.minWindowHeight)
    }
}
