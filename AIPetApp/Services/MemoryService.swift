import Foundation
import SwiftData

/// 负责管理 AIPet 的「长期记忆」：
/// - 从对话中抽取记忆
/// - 在对话前检索相关记忆
/// - 根据时间与重要度清理陈旧记忆
struct MemoryService {
    static let shared = MemoryService()

    private init() {}

    // MARK: - 对话前：记忆检索

    /// 根据当前宠物与可选关键字，检索相关记忆（优先高重要度 & 最近时间）。
    func fetchRelevantMemories(
        for pet: Pet,
        in context: ModelContext,
        query: String?,
        limit: Int = 8
    ) -> [MemoryEntry] {
        let descriptor = FetchDescriptor<MemoryEntry>(
            predicate: #Predicate { entry in
                entry.petID == pet.id
            },
            sortBy: [
                SortDescriptor(\.importance, order: .reverse),
                SortDescriptor(\.timestamp, order: .reverse)
            ]
        )

        let all: [MemoryEntry]
        do {
            all = try context.fetch(descriptor)
        } catch {
            print("[MemoryService] fetchRelevantMemories error: \(error)")
            return []
        }

        guard !all.isEmpty else { return [] }

        if let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            let lowered = q.lowercased()
            let filtered = all.filter { entry in
                entry.content.lowercased().contains(lowered)
            }
            if !filtered.isEmpty {
                return Array(filtered.prefix(limit))
            }
        }

        return Array(all.prefix(limit))
    }

    // MARK: - 对话后：记忆提取

    /// 基于最近一轮对话尝试抽取长期记忆，并落盘到 SwiftData。
    ///
    /// - Parameters:
    ///   - pet: 当前宠物
    ///   - messages: 当前宠物完整对话历史（已按时间排序）
    ///   - llmBaseURL: LLM Base URL（与聊天时保持一致）
    ///   - apiKey: LLM API Key
    ///   - modelName: 使用的模型名称
    ///   - context: SwiftData 持久化上下文
    func extractMemoriesIfNeeded(
        for pet: Pet,
        messages: [ChatMessage],
        llmBaseURL: URL?,
        apiKey: String,
        modelName: String,
        in context: ModelContext
    ) async {
        guard let baseURL = llmBaseURL,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // 未配置真实 LLM 时不进行长期记忆抽取，避免浪费本地 Mock 逻辑
            return
        }

        // 仅在对话长度达到一定阈值时尝试抽取，避免每条消息都触发网络请求。
        let nonSystem = messages.filter { $0.role != .system }
        guard nonSystem.count >= 6 else { return }

        // 取最近若干条用户/宠物对话，构造用于记忆抽取的上下文。
        let recentSlice = Array(nonSystem.suffix(12))
        let conversationText = recentSlice.map { msg in
            let speaker = (msg.role == .user) ? "用户" : pet.name
            return "\(speaker)：\(msg.content)"
        }.joined(separator: "\n")

        let systemPrompt = buildMemorySystemPrompt(for: pet)

        let cfg = LLMConfig(baseURL: baseURL, apiKey: apiKey, model: modelName)
        let llm = OpenAICompatibleLLMService(config: cfg)

        let raw: String
        do {
            raw = try await llm.sendMessage(
                systemPrompt: systemPrompt,
                history: [],
                userMessage: conversationText
            )
        } catch {
            print("[MemoryService] extractMemoriesIfNeeded LLM error: \(error)")
            return
        }

        let parsed = parseMemoryEntries(from: raw, pet: pet)
        guard !parsed.isEmpty else { return }

        // 持久化到 SwiftData
        do {
            for entry in parsed {
                context.insert(entry)
            }

            try context.save()
        } catch {
            print("[MemoryService] save memories error: \(error)")
        }

        // 轻量清理：删除非常久远且低重要度的记忆
        cleanMemoriesIfNeeded(for: pet, in: context)
    }

    // MARK: - 清理策略

    /// 根据时间 + 重要度进行简单清理，避免无限膨胀。
    func cleanMemoriesIfNeeded(for pet: Pet, in context: ModelContext) {
        let descriptor = FetchDescriptor<MemoryEntry>(
            predicate: #Predicate { entry in
                entry.petID == pet.id
            },
            sortBy: [
                SortDescriptor(\.timestamp, order: .reverse)
            ]
        )

        let all: [MemoryEntry]
        do {
            all = try context.fetch(descriptor)
        } catch {
            print("[MemoryService] cleanMemoriesIfNeeded fetch error: \(error)")
            return
        }

        guard !all.isEmpty else { return }

        // 保底保留最近的若干条重要记忆
        let maxCount = 200
        if all.count <= maxCount { return }

        let calendar = Calendar.current
        let now = Date()

        for entry in all {
            let isOld = calendar.dateComponents([.day], from: entry.timestamp, to: now).day ?? 0 > 180
            let isLowImportance = entry.importance <= 2

            if isOld && isLowImportance {
                context.delete(entry)
            }
        }

        do {
            try context.save()
        } catch {
            print("[MemoryService] cleanMemoriesIfNeeded save error: \(error)")
        }
    }

    // MARK: - 私有：Prompt & 解析

    private func buildMemorySystemPrompt(for pet: Pet) -> String {
        """
        你是虚拟宠物「\(pet.name)」，需要从对话中提取适合长期记忆的信息。

        现在会给你最近的一段对话记录，请你：
        1. 只保留对未来互动有帮助的关键信息，例如：用户的稳定偏好、长期目标、重要事件、家庭与工作背景、情绪模式等；
        2. 严格避免记住敏感隐私（如证件号、详细住址、银行卡号等）；
        3. 不要重复已有意思相同的记忆，尽量合并；
        4. 按以下 JSON 数组格式输出，不要添加任何多余说明：

        [
          {
            "content": "用户喜欢黑咖啡，不加糖",
            "category": "偏好",
            "importance": 4
          },
          {
            "content": "用户下周三有一场重要面试，最近情绪有些紧张",
            "category": "事件",
            "importance": 5
          }
        ]

        其中：
        - content: 一条简洁自然的中文句子；
        - category: 如「偏好」「事实」「情感」「事件」等中文标签；
        - importance: 1-5 的整数，越高越重要。
        """
    }

    private struct MemoryPayload: Decodable {
        let content: String
        let category: String
        let importance: Int
    }

    private func parseMemoryEntries(from raw: String, pet: Pet) -> [MemoryEntry] {
        let data: Data
        if let d = raw.data(using: .utf8) {
            data = d
        } else {
            return []
        }

        let decoder = JSONDecoder()
        do {
            let items = try decoder.decode([MemoryPayload].self, from: data)
            return items.compactMap { payload in
                let clampedImportance = max(1, min(5, payload.importance))
                return MemoryEntry(
                    pet: pet,
                    content: payload.content,
                    category: payload.category,
                    importance: clampedImportance
                )
            }
        } catch {
            // 如果解析失败，则退化为一条模糊记忆，避免整个流程完全失效。
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [
                MemoryEntry(
                    pet: pet,
                    content: trimmed,
                    category: "摘要",
                    importance: 3
                )
            ]
        }
    }
}

