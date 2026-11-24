import SwiftUI

struct DetailPlaceholderView: View {
    let selection: SidebarSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selection.title)
                .font(.title2)
                .fontWeight(.semibold)

            Text("页面占位：后续在这里实现\(selection.title)相关功能。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .navigationTitle(selection.title)
        .id(selection)
    }
}
