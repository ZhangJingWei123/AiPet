import Foundation
import SwiftData

/// 对话角色（SwiftData 持久化）
enum ChatMessageRole: String, Codable, CaseIterable {
    case user
    case pet
    case system
}

/// 单条对话消息（替代原 Interaction 模型）
@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var roleRawValue: String
    var content: String

    /// 图片二进制数据（可选，用户发送照片时使用）
    var imageData: Data?

    /// 宠物语音音频 URL（可选，后端返回 audio_url 时使用）
    var audioURLString: String?

    /// 所属宠物
    @Relationship var pet: Pet?

    var role: ChatMessageRole {
        get { ChatMessageRole(rawValue: roleRawValue) ?? .user }
        set { roleRawValue = newValue.rawValue }
    }

    /// 便捷访问音频 URL
    var audioURL: URL? {
        guard let audioURLString, let url = URL(string: audioURLString) else { return nil }
        return url
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = .init(),
        role: ChatMessageRole,
        content: String,
        pet: Pet? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.roleRawValue = role.rawValue
        self.content = content
        self.pet = pet
    }
}
