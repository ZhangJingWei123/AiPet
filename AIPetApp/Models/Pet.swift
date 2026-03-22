import Foundation
import SwiftData

/// 宠物基础信息与状态
@Model
final class Pet {
    @Attribute(.unique) var id: UUID
    var name: String
    var species: String
    var createdAt: Date

    /// 当前状态值（0-100）
    var energy: Int
    var sociability: Int
    var independence: Int

    /// 多重人格：决定整体对话基调
    /// - gentle: 温柔治愈系
    /// - sarcastic: 毒舌损友系
    /// - cool: 高冷克制系
    enum Personality: String, Codable, CaseIterable {
        case gentle
        case sarcastic
        case cool
    }

    /// 当前选中的人格模式（默认 gentle）。
    ///
    /// 注意：高级性格 DNA（如 isSnarkyGenius）仍然通过 PersonalityDNA 表达；
    /// 这里的人格是一个更“表层”的对话风格开关，便于一键切换。
    var personality: Personality = .gentle

    /// 绑定的性格 DNA
    @Relationship var personalityDNA: PersonalityDNA?

    /// 所在家园
    @Relationship var home: Home?

    /// 对话历史（基于 ChatMessage 持久化）
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.pet) var messages: [ChatMessage]

    /// 长期记忆条目
    @Relationship(deleteRule: .cascade, inverse: \MemoryEntry.pet) var memories: [MemoryEntry]

    init(
        id: UUID = UUID(),
        name: String,
        species: String,
        createdAt: Date = .init(),
        energy: Int = 50,
        sociability: Int = 50,
        independence: Int = 50,
        personality: Personality = .gentle,
        personalityDNA: PersonalityDNA? = nil,
        home: Home? = nil
    ) {
        self.id = id
        self.name = name
        self.species = species
        self.createdAt = createdAt
        self.energy = energy
        self.sociability = sociability
        self.independence = independence
        self.personality = personality
        self.personalityDNA = personalityDNA
        self.home = home
        self.messages = []
        self.memories = []
    }
}
