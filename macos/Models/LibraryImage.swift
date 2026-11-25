import Foundation

/// 图片库条目：裁剪成品、量化图与处理配置的元数据。
/// 成品图与量化图文件位于库目录下以 id 命名的子目录中。
struct LibraryImage: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var addedAt: Date
    var configuration: ImageEditConfiguration
}
