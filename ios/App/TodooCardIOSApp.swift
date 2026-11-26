import SwiftUI

@main
struct TodooCardIOSApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// 应用根视图：图片 / 设备两个标签页，装配图片库、处理与蓝牙服务。
struct RootView: View {
    @StateObject private var imageProcessor = ImageProcessor()
    @StateObject private var imageLibrary = ImageLibrary()
    @StateObject private var transferService = TodooCardTransferService()
    @StateObject private var deviceScanner = DeviceScanner()

    var body: some View {
        TabView {
            ImageLibraryView(
                processor: imageProcessor,
                library: imageLibrary,
                transferService: transferService
            )
            .tabItem {
                Label(SidebarSection.image.title, systemImage: SidebarSection.image.systemImage)
            }

            DeviceView(scanner: deviceScanner)
                .tabItem {
                    Label(SidebarSection.device.title, systemImage: SidebarSection.device.systemImage)
                }
        }
        .onAppear {
            imageProcessor.attach(library: imageLibrary)
            #if DEBUG
            UITestSeed.run(processor: imageProcessor, library: imageLibrary)
            #endif
            imageLibrary.loadOnLaunch()
        }
    }
}
