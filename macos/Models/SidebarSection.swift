import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case image
    case device

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image:
            return "图片"
        case .device:
            return "设备"
        }
    }

    var systemImage: String {
        switch self {
        case .image:
            return "photo"
        case .device:
            return "dot.radiowaves.left.and.right"
        }
    }
}
