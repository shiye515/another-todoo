import CoreGraphics
import Foundation

enum ImageProcessStep: Equatable {
    case selection
    case cropping
    case quantization
}

/// 图像编辑参数（纯值类型，可在任意线程传递）。
struct ImageEditConfiguration: Equatable, Sendable {
    var targetWidth: Int
    var targetHeight: Int
    var rotationDegrees: Int
    var cropMode: CropMode
    var zoom: Double
    var horizontalOffset: Double
    var verticalOffset: Double
    var ditheringEnabled: Bool

    static let todooCard528x792 = ImageEditConfiguration(
        targetWidth: 528,
        targetHeight: 792,
        rotationDegrees: 0,
        cropMode: .target,
        zoom: 1,
        horizontalOffset: 0.5,
        verticalOffset: 0.5,
        ditheringEnabled: true
    )
}

enum CropMode: String, CaseIterable, Identifiable {
    case target = "按目标比例"
    case square = "正方形"
    case fourThree = "4:3"
    case threeFour = "3:4"

    var id: String { rawValue }

    var aspectRatio: CGFloat? {
        switch self {
        case .target:
            return nil
        case .square:
            return 1
        case .fourThree:
            return 4.0 / 3.0
        case .threeFour:
            return 3.0 / 4.0
        }
    }
}
