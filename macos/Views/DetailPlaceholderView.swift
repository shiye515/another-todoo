import SwiftUI

struct DetailPlaceholderView: View {
    let selection: SidebarSection
    let deviceScanner: DeviceScanner
    @StateObject private var imageProcessor = ImageProcessor()
    @StateObject private var transferService = TodooCardTransferService()

    var body: some View {
        Group {
            switch selection {
            case .image:
                ImageView(
                    processor: imageProcessor,
                    transferService: transferService
                )
            case .device:
                DeviceView(scanner: deviceScanner)
            }
        }
        .navigationTitle(selection.title)
        .id(selection)
    }
}
