import Foundation
import SwiftData

/// 长期记忆条目模型
///
/// - 每条记录属于某一只宠物（petID + 关系字段）
/// - content: 记忆内容（例如："用户喜欢黑咖啡"）
/// - category: 记忆类别（偏好、事实、情感等，自由字符串）
/// - importance: 重要度 1-5，数值越大越重要
@Model
final class MemoryEntry {
    @Attribute(.unique) var id: UUID

    /// 便于快速查询的冗余字段（同时通过 Relationship 关联 Pet）
    var petID: UUID

    var content: String
    var category: String
    var timestamp: Date
    var importance: Int

    /// 所属宠物（反向关系：Pet.memories）
    @Relationship var pet: Pet?

    init(
        id: UUID = UUID(),
        pet: Pet,
        content: String,
        category: String,
        timestamp: Date = .init(),
        importance: Int = 3
    ) {
        self.id = id
        self.petID = pet.id
        self.content = content
        self.category = category
        self.timestamp = timestamp
        self.importance = importance
        self.pet = pet
    }
}

