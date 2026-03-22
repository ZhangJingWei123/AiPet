import Foundation
import SwiftData

/// 家园与场景（简化，支持多宠同居和 2.5D 视觉骨架）
@Model
final class Home {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date

    /// 背景主题（如：livingRoom、bedroom、yard），用于 2.5D 渲染时选择资源
    var theme: String

    /// 家具配置 JSON（预留给后续家园编辑器）
    var furnitureLayoutJSON: String

    /// 当前家园中的宠物
    @Relationship(inverse: \Pet.home) var pets: [Pet]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .init(),
        theme: String = "livingRoom",
        furnitureLayoutJSON: String = "{}"
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.theme = theme
        self.furnitureLayoutJSON = furnitureLayoutJSON
        self.pets = []
    }
}

