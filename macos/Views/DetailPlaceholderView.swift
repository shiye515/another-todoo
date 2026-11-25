import SwiftUI

struct DetailPlaceholderView: View {
    let selection: SidebarSection
    let deviceScanner: DeviceScanner
    @StateObject private var imageProcessor = ImageProcessor()
    @StateObject private var imageLibrary = ImageLibrary()
    @StateObject private var transferService = TodooCardTransferService()

    var body: some View {
        Group {
            switch selection {
            case .image:
                ImageView(
                    processor: imageProcessor,
                    library: imageLibrary,
                    transferService: transferService
                )
            case .device:
                DeviceView(scanner: deviceScanner)
            }
        }
        .navigationTitle(selection.title)
        .onAppear {
            imageProcessor.attach(library: imageLibrary)
            imageLibrary.loadOnLaunch()
        }
    }
}
