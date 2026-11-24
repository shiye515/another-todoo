import SwiftUI

struct ContentView: View {
    @State private var selection: SidebarSection = .image

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            DetailPlaceholderView(selection: selection)
        }
        .navigationTitle(selection.title)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}
