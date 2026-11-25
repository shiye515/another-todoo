import Foundation

/// 量化变体注册表：详情区变体卡片、持久化文件与量化参数的单一真源。
/// 新增算法 = 在 `registry` 追加一项，卡片自动出现在变体行末尾。
/// `isPlanned` 项仅在详情区生成占位卡，不参与计算、持久化与发送。
struct QuantizedVariant: Identifiable, Hashable {
    let id: String
    /// 卡片标题（如 "Floyd–Steinberg"）。
    let name: String
    /// 参数摘要（如 "误差扩散抖动"）。
    let subtitle: String
    /// 卡片/操作栏说明文案。
    let summary: String
    /// 规划中的算法：仅占位卡，不产出文件。
    let isPlanned: Bool
    /// 持久化文件名（条目目录内）。
    let fileName: String
    /// 量化参数映射：误差扩散算法。
    let algorithm: QuantizationAlgorithm

    static let registry: [QuantizedVariant] = [
        QuantizedVariant(
            id: "plain",
            name: "标准量化",
            subtitle: "无抖动",
            summary: "色块干净、边缘锐利，适合几何图形与文字",
            isPlanned: false,
            fileName: "quantized.png",
            algorithm: .none
        ),
        QuantizedVariant(
            id: "floyd",
            name: "Floyd–Steinberg",
            subtitle: "误差扩散抖动",
            summary: "渐变过渡自然，适合照片类图像",
            isPlanned: false,
            fileName: "dithered.png",
            algorithm: .floydSteinberg
        ),
        QuantizedVariant(
            id: "atkinson",
            name: "Atkinson",
            subtitle: "误差扩散抖动",
            summary: "对比度略高、细节保留更好，适合明暗对比强的图像",
            isPlanned: false,
            fileName: "atkinson.png",
            algorithm: .atkinson
        ),
        QuantizedVariant(
            id: "ostromoukhov",
            name: "Ostromoukhov",
            subtitle: "误差扩散抖动",
            summary: "蓝噪声频谱、纹理更均匀，适合大面积渐变与照片",
            isPlanned: false,
            fileName: "ostromoukhov.png",
            algorithm: .ostromoukhov
        ),
    ]

    /// 已实现变体：参与计算、持久化、选中与发送的全部变体。
    static var implemented: [QuantizedVariant] {
        registry.filter { !$0.isPlanned }
    }

    /// 按 id 查找已实现变体；规划中或未知 id 返回 nil（不可选中、不持久化）。
    static func implementedVariant(withID id: String) -> QuantizedVariant? {
        implemented.first { $0.id == id }
    }
}
