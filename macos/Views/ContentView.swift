import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarSection = .image
    @StateObject private var deviceScanner = DeviceScanner()

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            DetailPlaceholderView(selection: selection, deviceScanner: deviceScanner)
        }
        .navigationTitle(selection.title)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}
