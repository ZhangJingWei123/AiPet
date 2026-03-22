import Foundation
import SwiftData

/// 性格 DNA，用来驱动 LLM System Prompt
@Model
final class PersonalityDNA {
    /// 关联的宠物（可选：允许一个 DNA 模板被多个宠物复用）
    @Relationship(inverse: \Pet.personalityDNA) var pet: Pet?

    /// 能量值：0-100，越高越活泼
    var energy: Int

    /// 社交性：0-100，越高越粘人、爱互动
    var sociability: Int

    /// 独立性：0-100，越高越高冷、需要个人空间
    var independence: Int

    /// 好奇心：0-100，越高越喜欢提问、探索
    var curiosity: Int

    /// 温柔度：0-100，越高语气越柔和
    var tenderness: Int

    /// 是否启用「高智商毒舌助手」高级性格 DNA
    /// - 该开关主要影响 System Prompt 的整体风格，而不是单一数值维度
    var isSnarkyGenius: Bool

    init(
        energy: Int = 50,
        sociability: Int = 50,
        independence: Int = 50,
        curiosity: Int = 50,
        tenderness: Int = 50,
        isSnarkyGenius: Bool = false
    ) {
        self.energy = energy
        self.sociability = sociability
        self.independence = independence
        self.curiosity = curiosity
        self.tenderness = tenderness
        self.isSnarkyGenius = isSnarkyGenius
    }
}
