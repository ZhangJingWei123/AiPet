import Foundation

/// 占位：根据真实宠物的照片/问卷/行为数据，推导 PersonalityDNA
///
/// 后续可以结合 PRD 中的「真实宠物导入」流程：
/// - 输入：
///   - 宠物照片（毛色、体型、表情特征等）
///   - 主人填写的问卷（活泼程度、是否胆小、与人的关系等）
///   - 行为日志（喂食时间、陪玩频率等）
/// - 输出：
///   - 一个可用于驱动 LLM 的 PersonalityDNA 对象
protocol PhotoDNABuilder {
    /// 将原始输入特征转换为标准化的 PersonalityDNA
    func buildDNA(from payload: PhotoDNABuilderPayload) async throws -> PersonalityDNA
}

/// 真实导入数据的聚合载体，占位定义
struct PhotoDNABuilderPayload {
    /// 原始宠物照片二进制（可为空，只基于问卷）
    var photoData: Data?

    /// 问卷答案：key 为问题 id，value 为用户选择/填空内容
    var questionnaireAnswers: [String: String]

    /// 行为相关元信息（例如："play_times_per_day": "3"）
    var behaviorSignals: [String: String]
}

/// 默认空实现，仅返回中性 DNA，方便 UI 联调
struct DummyPhotoDNABuilder: PhotoDNABuilder {
    func buildDNA(from payload: PhotoDNABuilderPayload) async throws -> PersonalityDNA {
        PersonalityDNA(
            energy: 50,
            sociability: 50,
            independence: 50,
            curiosity: 50,
            tenderness: 50
        )
    }
}

