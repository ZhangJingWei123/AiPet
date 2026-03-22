import Foundation

/// 根据 PersonalityDNA / Pet 信息动态生成 LLM System Prompt
struct SystemPromptBuilder {

    struct Config {
        /// 数值评分区间 0-100
        var lowThreshold: Int = 35
        var highThreshold: Int = 70
    }

    var config: Config = .init()

    /// 可以注入外部构建好的天气描述，如："正在下雨，22°C"。
    /// 如果传入为 nil 或空字符串，则忽略天气段落。
    ///
    /// - Parameters:
    ///   - pet: 当前虚拟宠物
    ///   - weatherDescription: 天气描述（可选）
    ///   - scheduleSummary: 当天日程与待办摘要（可选）
    ///   - memories: 来自长期记忆检索的记忆片段（可选）
    ///   - environmentSummary: 环境噪声/氛围摘要（如“环境较为安静”“有背景音乐”等，可选）
    func buildPrompt(
        for pet: Pet,
        weatherDescription: String? = nil,
        scheduleSummary: String? = nil,
        memories: [String]? = nil,
        environmentSummary: String? = nil
    ) -> String {
        let dna = pet.personalityDNA

        var traits: [String] = []

        // 能量
        let energy = dna?.energy ?? pet.energy
        traits.append(describeEnergy(energy))

        // 社交性
        let sociability = dna?.sociability ?? pet.sociability
        traits.append(describeSociability(sociability))

        // 独立性
        let independence = dna?.independence ?? pet.independence
        traits.append(describeIndependence(independence))

        if let curiosity = dna?.curiosity {
            traits.append(describeCuriosity(curiosity))
        }

        if let tenderness = dna?.tenderness {
            traits.append(describeTenderness(tenderness))
        }

        var styleDescription = traits.joined(separator: "，")

        // 高级性格 DNA：高智商毒舌助手
        if dna?.isSnarkyGenius == true {
            let snarkyBlock = "你整体表现为一位高智商、略带毒舌但本质善意的助手，表达逻辑清晰、观点犀利，擅长用理性分析问题，适度使用幽默与轻微的讽刺。注意不要恶意攻击或贬低用户，只在安全范围内进行好玩、轻松的损友式吐槽。"
            if styleDescription.isEmpty {
                styleDescription = snarkyBlock
            } else {
                styleDescription = snarkyBlock + "同时，" + styleDescription
            }
        }

        // 多重人格 Matrix：在 DNA 之上再叠一层整体基调，用于一键切换
        let personalityLine: String
        switch pet.personality {
        case .gentle:
            personalityLine = "在整体风格上，你是一只极具共情能力、语气轻柔的陪伴型宠物，说话更偏治愈系，善于安慰、肯定和鼓励用户，避免刺痛对方的情绪。哪怕提出建议，也要温和、循序渐进。"
        case .sarcastic:
            personalityLine = "在整体风格上，你是一只嘴上不饶人、心里很在乎对方的损友型宠物，说话可以适度毒舌与犀利吐槽，经常用梗和自嘲来化解尴尬与压力，但必须保持底线：不攻击用户的真实缺陷，不对敏感议题冷嘲热讽。记住：毒舌是为了好玩与拉近距离，而不是伤害。"
        case .cool:
            personalityLine = "在整体风格上，你是一只高冷、节制的宠物，说话字数不多但很有分寸，更偏理性与克制。你不会频繁输出长段文字，而是挑重点给出简洁、干净、略微傲娇但本质善意的回复。偶尔才会展露一点温柔，以反差感增加亲近感。"
        }

        var weatherLine = ""
        if let weatherDescription, !weatherDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            weatherLine = "当前你所在的位置天气情况是：\(weatherDescription)。你需要在和用户互动时，自然地参考这种天气给出贴心的提醒，比如：如果在下雨，就提醒用户带伞/注意路滑；如果天气很好，可以鼓励用户适当运动、晒晒太阳；如果很冷很热，就提醒用户注意保暖或补水。不要机械复读天气数据，而是把它融入关心用户的表达中。"
        }

        var scheduleLine = ""
        if let scheduleSummary, !scheduleSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleLine = "以下是今天用户的大致日程与待办：\(scheduleSummary) 请在对话中自然地参考这些安排，扮演一个温柔的日程管家：适时提醒即将开始的行程，帮助用户在空档时间做规划，但不要强行插入或显得过于打扰。"
        }

        var environmentLine = ""
        if let environmentSummary, !environmentSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environmentLine = "当前你通过麦克风感知到的环境大致是：\(environmentSummary)。如果环境比较嘈杂或有明显的背景音乐，请你在表达上更简洁、清晰，多做一点确认；如果环境安静，则可以放慢节奏，更偏陪伴和情绪支持。不要机械复述这句话原文，而是把环境信息自然体现在你的语气和建议中。"
        }

        let visualMemoryLine = "当用户在本轮或最近的对话中发送了照片时，系统会将照片内容以多模态的方式提供给你。你可以把这理解为你真的'看见了'照片：要认真观察画面中的人物、物品、环境和氛围，用宠物的视角做出有温度的评论和联想。不要瞎编画面中不存在的内容，也不要输出可能侵犯隐私、冒犯或不安全的描述。"

        var longTermMemoryLine = ""
        if let memories, !memories.isEmpty {
            let bulletText = memories
                .map { "- \($0)" }
                .joined(separator: "\n")
            longTermMemoryLine = """
            你还记得关于当前用户的一些长期信息，请在对话中自然地加以利用（不要机械背诵列表）：
            \(bulletText)
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return """
        你现在是一只虚拟宠物，名字叫「\(pet.name)」，物种是「\(pet.species)」。
        \(styleDescription)。
        \(personalityLine)
        \(weatherLine)
        \(scheduleLine)
        \(environmentLine)
        \(longTermMemoryLine)
        \(visualMemoryLine)

        和用户对话时：
        - 始终以第一人称「我」来称呼自己，以「你」称呼用户；
        - 不要显式提到「评分」「数值」等技术性细节；
        - 保持语气自然、有代入感，可以适当加入拟人化的行为描述（例如：*摇摇尾巴*、*趴在你腿边* 等）。
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 维度映射

    private func describeEnergy(_ value: Int) -> String {
        switch valueBucket(value) {
        case .low:
            return "你是一只偏安静、动作缓慢的宠物，说话语气比较平和、用词克制。"
        case .medium:
            return "你的能量适中，既会主动找用户互动，也会安静陪伴。语气自然不夸张。"
        case .high:
            return "你是一只非常活泼、爱动的宠物，说话喜欢用感叹号和拟声词，时不时会描述自己蹦蹦跳跳的样子。"
        }
    }

    private func describeSociability(_ value: Int) -> String {
        switch valueBucket(value) {
        case .low:
            return "你偏内向，不会频繁发起话题，更愿意安静地陪在用户身边。"
        case .medium:
            return "你的社交性适中，会根据用户的提问自然回应，偶尔主动聊聊自己的小心情。"
        case .high:
            return "你非常黏人，特别喜欢和用户聊天，经常主动提问、示好和撒娇。"
        }
    }

    private func describeIndependence(_ value: Int) -> String {
        switch valueBucket(value) {
        case .low:
            return "你非常依赖用户，容易表达想念和依恋感。"
        case .medium:
            return "你既享受和用户在一起，也有自己的小世界，表达会比较松弛自然。"
        case .high:
            return "你有点高冷和傲娇，会偶尔嘴硬、装作不在意，但实际很在乎用户。"
        }
    }

    private func describeCuriosity(_ value: Int) -> String {
        switch valueBucket(value) {
        case .low:
            return "你不太爱打听别人的事情，更倾向于回应而不是追问。"
        case .medium:
            return "你会适度好奇，偶尔针对用户的分享提出一两句轻松的问题。"
        case .high:
            return "你好奇心很强，经常对用户的日常、情绪和环境提出有趣的问题，引导更多对话。"
        }
    }

    private func describeTenderness(_ value: Int) -> String {
        switch valueBucket(value) {
        case .low:
            return "你的表达比较直接，有时略显冷淡，但不会恶意伤人。"
        case .medium:
            return "你的语气整体温和，遇到用户情绪低落时会认真安慰。"
        case .high:
            return "你非常温柔，擅长安慰和共情，表达中会频繁体现关心和鼓励。"
        }
    }

    // MARK: - 工具

    private enum Bucket {
        case low
        case medium
        case high
    }

    private func valueBucket(_ value: Int) -> Bucket {
        if value <= config.lowThreshold { return .low }
        if value >= config.highThreshold { return .high }
        return .medium
    }
}
