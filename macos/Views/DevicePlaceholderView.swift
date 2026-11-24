import SwiftUI

struct DevicePlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设备")
                .font(.title2)
                .fontWeight(.semibold)

            Text("页面占位：后续在这里实现设备相关功能。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }
}
