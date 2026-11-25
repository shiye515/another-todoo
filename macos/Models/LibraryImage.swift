import Foundation

/// 图片库条目：裁剪成品、量化图与处理配置的元数据。
/// 成品图与量化图文件位于库目录下以 id 命名的子目录中。
struct LibraryImage: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var addedAt: Date
    var configuration: ImageEditConfiguration
    /// 当前选中的量化变体 id（底部统一发送的版本）；nil = 未选中。
    /// 旧版 manifest 缺省该字段时解码为 nil（向后兼容）。
    var selectedVariantID: String?
}
