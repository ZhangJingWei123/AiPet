import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation
import UIKit

/// 宠物对话界面（前端 UI + 本地假对话逻辑）
struct ChatInterfaceView: View {
    @Environment(\.modelContext) private var context
    @Query private var messages: [ChatMessage]
    @Query private var memoryEntries: [MemoryEntry]

    @EnvironmentObject private var authService: AuthService

    let pet: Pet

    @State private var inputText: String = ""
    @State private var isSending: Bool = false

    /// 是否正在发送图片消息（避免重复点击）
    @State private var isSendingImage: Bool = false

    @State private var isTyping: Bool = false
    @State private var streamingText: String? = nil

    @State private var showLoginAlert: Bool = false

    @State private var showStaminaDepletedSheet: Bool = false

    /// 当前已加载的可见消息数量（用于下拉加载更多）
    @State private var loadedMessageCount: Int = 40

    /// 选中的系统相册图片
    @State private var selectedPhotoItem: PhotosPickerItem?

    /// 聊天语音播放管理
    @StateObject private var audioManager = AudioPlayerManager()

    /// 全双工语音模式：常驻麦克风 + 实时听写 + 可打断
    @StateObject private var voiceInteractionService = VoiceInteractionService()
    @State private var isFullDuplexModeOn: Bool = false
    @State private var latestEnvironmentSummary: String? = nil

    @AppStorage("llm_base_url") private var llmBaseURLString: String = "https://api.openai.com"
    @AppStorage("llm_api_key") private var llmAPIKey: String = ""
    @AppStorage("llm_model_name") private var llmModelName: String = "gpt-4.1-mini"

    /// 最近一次获取到的天气描述（例如："正在下雨，22°C"）
    @State private var latestWeatherDescription: String? = nil

    /// 语音自动播放配置
    @AppStorage("voice_auto_play") private var voiceAutoPlay: Bool = false

    /// 记忆透明化弹窗
    @State private var showMemorySheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // 记忆透明化入口（展示当前宠物的记忆摘要 / RAG 上下文）
            if let latestMemoryText {
                MemoryEntryView(text: latestMemoryText)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .onTapGesture {
                        showMemorySheet = true
                    }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(displayedMessages, id: \.id) { message in
                            ChatBubbleView(message: message, pet: pet, audioManager: audioManager)
                                .id(message.id)
                        }

                        if isTyping {
                            StreamingBubbleView(text: streamingText ?? "", pet: pet)
                                .id("typingBubble")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
                .refreshable {
                    await loadMoreHistoryIfPossible()
                }
                .background(Color(.systemBackground))
                .onChange(of: displayedMessages.count) { _ in
                    if let last = displayedMessages.last {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: streamingText) { _ in
                    if isTyping {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("typingBubble", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // 非 Plus 会员的对话次数提示
            if authService.isLoggedIn && !authService.isPlusActive {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.heart.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("今日剩余对话：\(remainingQuotaToday)/\(dailyLimitNormalUser)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .padding(.horizontal, 8)
            }

            HStack(alignment: .bottom, spacing: 8) {
                // 图片发送入口
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary, .secondary)
                        .padding(6)
                        .background(
                            .ultraThinMaterial,
                            in: Circle()
                        )
                }
                .disabled(isSending || isSendingImage || !authService.isLoggedIn)

                // 全双工语音模式开关
                Button {
                    toggleFullDuplexMode()
                } label: {
                    Image(systemName: isFullDuplexModeOn ? "waveform.circle.fill" : "mic.circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isFullDuplexModeOn ? .red : .primary)
                        .padding(6)
                        .background(
                            .ultraThinMaterial,
                            in: Circle()
                        )
                }
                .disabled(isSending || !authService.isLoggedIn)

                TextField("对宠物说点什么…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)

                Button(action: sendMessage) {
                    if isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || !authService.isLoggedIn)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .alert("请先登录", isPresented: $showLoginAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("登录后才能继续和 AIPet 对话。")
        }
        .sheet(isPresented: $showStaminaDepletedSheet) {
            AIPetPlusView(source: .limitReached)
                .environmentObject(authService)
        }
        .sheet(isPresented: $showMemorySheet) {
            MemoryDetailView(memories: longTermMemoriesForCurrentPet, pet: pet)
        }
        .onAppear {
            AnalyticsService.shared.trackEvent(
                "chat_view_appear",
                props: [
                    "pet_id": pet.id.uuidString,
                    "pet_name": pet.name
                ]
            )

            // 进入对话界面时尝试拉取一次最新天气，用于后续系统提示词。
            Task {
                _ = await refreshWeatherIfPossible()
            }
        }
        .onChange(of: selectedPhotoItem) { newItem in
            guard let item = newItem else { return }
            Task {
                await handleSelectedPhoto(item)
            }
        }
        .onReceive(voiceInteractionService.$transcribedText) { text in
            guard isFullDuplexModeOn else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            // 当 VAD 认为一轮语音输入结束时，VoiceInteractionService 会产出完整的转写文本
            // 这里复用 sendMessage 管线：将转写结果直接发送给宠物
            inputText = text
            sendMessage()
        }
        .onReceive(voiceInteractionService.$environmentSummary) { summary in
            if let summary, !summary.isEmpty {
                latestEnvironmentSummary = summary
            }
        }
    }

    // MARK: - 数据视图与 LLM 映射

    /// 该宠物的全部对话（含 system 摘要）
    private var allMessagesForCurrentPet: [ChatMessage] {
        messages
            .filter { $0.pet?.id == pet.id }
            .sorted(by: { $0.createdAt < $1.createdAt })
    }

    /// 展示给用户的对话（过滤掉内部 system 摘要），并按分页数量裁剪
    private var displayedMessages: [ChatMessage] {
        let allVisible = allMessagesForCurrentPet.filter { $0.role != .system }
        guard !allVisible.isEmpty else { return [] }

        let count = allVisible.count
        let limit = max(1, min(count, loadedMessageCount))
        return Array(allVisible.suffix(limit))
    }

    /// 当前宠物的长期记忆列表
    private var longTermMemoriesForCurrentPet: [MemoryEntry] {
        memoryEntries
            .filter { $0.petID == pet.id }
            .sorted { lhs, rhs in
                if lhs.importance == rhs.importance {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.importance > rhs.importance
            }
    }

    /// 最新一条长期记忆摘要文案
    private var latestMemoryText: String? {
        longTermMemoriesForCurrentPet.first?.content
    }

    /// 提供给 LLM 的历史记录
    private var historyMessages: [LLMChatMessage] {
        allMessagesForCurrentPet.map { message in
            let role: LLMChatMessage.Role
            switch message.role {
            case .user:
                role = .user
            case .pet:
                role = .assistant
            case .system:
                role = .system
            }
            return LLMChatMessage(role: role, content: message.content)
        }
    }

    // MARK: - 对话次数统计（前端近似，用于 UI 提示）

    private let dailyLimitNormalUser: Int = 20

    /// 当前宠物今日已发送的用户消息条数
    private var todayUserMessageCount: Int {
        let calendar = Calendar.current
        return allMessagesForCurrentPet.filter { message in
            message.role == .user && calendar.isDateInToday(message.createdAt)
        }.count
    }

    /// 今日剩余可用对话次数（仅用于展示，不作为强校验）
    private var remainingQuotaToday: Int {
        max(0, dailyLimitNormalUser - todayUserMessageCount)
    }

    /// 是否配置了真实 LLM
    private var useRealLLM: Bool {
        !llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 当前激活的服务：优先真实 LLM，退回 Mock
    private var activeLLMService: any LLMService {
        if useRealLLM,
           let url = URL(string: llmBaseURLString),
           !llmModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cfg = LLMConfig(baseURL: url, apiKey: llmAPIKey, model: llmModelName)
            return OpenAICompatibleLLMService(config: cfg)
        } else {
            return MockLLMService()
        }
    }

    // MARK: - 发送图片消息

    /// 处理系统相册中选中的图片
    private func handleSelectedPhoto(_ item: PhotosPickerItem) async {
        guard authService.isLoggedIn else {
            await MainActor.run {
                showLoginAlert = true
                selectedPhotoItem = nil
            }
            return
        }

        await MainActor.run {
            isSendingImage = true
        }

        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                sendImageMessage(imageData: data)
            }
        } catch {
            print("加载图片失败: \(error)")
        }

        await MainActor.run {
            isSendingImage = false
            selectedPhotoItem = nil
        }
    }

    /// 将图片作为一条独立消息发送给宠物
    private func sendImageMessage(imageData: Data) {
        guard authService.isLoggedIn else {
            showLoginAlert = true
            return
        }

        let userText = "我给你发了一张照片，你暂时看不到具体内容，但可以用宠物的语气回应我。"

        AnalyticsService.shared.trackEvent(
            "chat_send_image",
            props: [
                "pet_id": pet.id.uuidString,
                "pet_name": pet.name
            ]
        )

        Task {
            // 1. 插入带图片的用户消息
            await MainActor.run {
                let userMessage = ChatMessage(role: .user, content: userText, pet: pet)
                userMessage.imageData = imageData
                context.insert(userMessage)
                do {
                    try context.save()
                } catch {
                    print("保存图片消息失败: \(error)")
                }
            }

            // 2. 可能触发记忆摘要
            await summarizeIfNeeded()

            let weather = await refreshWeatherIfPossible() ?? latestWeatherDescription
            let scheduleSummary = await fetchTodayScheduleSummary()

            let memoryTexts = await MainActor.run { () -> [String] in
                let relevant = MemoryService.shared.fetchRelevantMemories(
                    for: pet,
                    in: context,
                    query: userText
                )
                return relevant.map { $0.content }
            }

            let systemPrompt = SystemPromptBuilder().buildPrompt(
                for: pet,
                weatherDescription: weather,
                scheduleSummary: scheduleSummary,
                memories: memoryTexts.isEmpty ? nil : memoryTexts,
                environmentSummary: latestEnvironmentSummary
            )
            let history = await MainActor.run { historyMessages }
            var finalReply = ""

            await MainActor.run {
                isTyping = true
                streamingText = ""
            }

            // 3. 调用 LLM（与文本消息一致，但会在底层携带图片的 base64 数据做多模态推理）
            do {
                let service = activeLLMService
                let imageBase64: String? = {
                    // 将图片统一转为 JPEG 再编码为 base64，兼顾大小与兼容性
                    if let uiImage = UIImage(data: imageData),
                       let jpegData = uiImage.jpegData(compressionQuality: 0.8) {
                        return jpegData.base64EncodedString()
                    } else {
                        return imageData.base64EncodedString()
                    }
                }()
                finalReply = try await service.sendMessageStreaming(
                    systemPrompt: systemPrompt,
                    history: history,
                    userMessage: userText,
                    imageBase64: imageBase64
                ) { token in
                    Task { @MainActor in
                        if streamingText == nil { streamingText = "" }
                        streamingText? += token
                    }
                }
            } catch {
                if case let LLMError.httpError(statusCode, body) = error,
                   statusCode == 403,
                   body.contains("LIMIT_REACHED") {
                    await MainActor.run {
                        isTyping = false
                        streamingText = nil
                        isSending = false
                        isSendingImage = false
                        showStaminaDepletedSheet = true
                    }

                    AnalyticsService.shared.trackEvent(
                        "chat_limit_reached",
                        props: [
                            "pet_id": pet.id.uuidString,
                            "pet_name": pet.name
                        ]
                    )
                    return
                }

                print("LLM 调用失败，回退到 Mock: \(error)")
                let mock = MockLLMService()
                do {
                    finalReply = try await mock.sendMessage(systemPrompt: systemPrompt, history: history, userMessage: userText)
                } catch {
                    finalReply = "*垂耳* 我好像暂时连不上大脑了，稍后再试试好吗？"
                }
            }

            let decoded = decodePetReply(from: finalReply)

            // 4. 保存宠物回复
            await MainActor.run {
                let petMessage = ChatMessage(role: .pet, content: decoded.text, pet: pet)
                petMessage.audioURLString = decoded.audioURL
                context.insert(petMessage)
                do {
                    try context.save()
                } catch {
                    print("保存宠物对话失败: \(error)")
                }

                isTyping = false
                streamingText = nil
                isSending = false
                isSendingImage = false
                loadedMessageCount = max(loadedMessageCount, displayedMessages.count + 2)

                if voiceAutoPlay,
                   let urlString = decoded.audioURL,
                   let url = URL(string: urlString) {
                    audioManager.play(url: url, for: petMessage.id)
                }
            }

            let estimatedTokens = (userText.count + decoded.text.count) / 4
            AnalyticsService.shared.trackEvent(
                "llm_reply_completed",
                props: [
                    "pet_id": pet.id.uuidString,
                    "pet_name": pet.name,
                    "estimated_tokens": estimatedTokens
                ]
            )

            // 5. 在后台尝试抽取长期记忆
            let baseURL = URL(string: llmBaseURLString)
            let apiKey = llmAPIKey
            let modelName = llmModelName
            let allMessages = await MainActor.run { allMessagesForCurrentPet }

            Task {
                await MemoryService.shared.extractMemoriesIfNeeded(
                    for: pet,
                    messages: allMessages,
                    llmBaseURL: baseURL,
                    apiKey: apiKey,
                    modelName: modelName,
                    in: context
                )
            }
        }
    }

    private func sendMessage() {
        guard authService.isLoggedIn else {
            showLoginAlert = true
            return
        }

        var text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 在全双工模式下，如果输入框为空但语音识别已有结果，则优先使用最近一轮语音转写
        if text.isEmpty,
           isFullDuplexModeOn,
           let spoken = voiceInteractionService.transcribedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !spoken.isEmpty {
            text = spoken
        }
        guard !text.isEmpty else { return }

        inputText = ""
        isSending = true
        let userText = text

        // 若在全双工模式下，用户开始说话则打断当前 TTS 播放
        if isFullDuplexModeOn {
            audioManager.pause()
        }

        AnalyticsService.shared.trackEvent(
            "chat_send",
            props: [
                "pet_id": pet.id.uuidString,
                "pet_name": pet.name,
                "text_length": userText.count
            ]
        )

        Task {
            // 1. 插入用户消息
            await MainActor.run {
                let userMessage = ChatMessage(role: .user, content: userText, pet: pet)
                context.insert(userMessage)
                do {
                    try context.save()
                } catch {
                    print("保存用户对话失败: \(error)")
                }
            }

            // 2. 记忆摘要（可能会插入/删除多条 Interaction）
            await summarizeIfNeeded()

            let weather = await refreshWeatherIfPossible() ?? latestWeatherDescription
            let scheduleSummary = await fetchTodayScheduleSummary()

            let memoryTexts = await MainActor.run { () -> [String] in
                let relevant = MemoryService.shared.fetchRelevantMemories(
                    for: pet,
                    in: context,
                    query: userText
                )
                return relevant.map { $0.content }
            }

            let systemPrompt = SystemPromptBuilder().buildPrompt(
                for: pet,
                weatherDescription: weather,
                scheduleSummary: scheduleSummary,
                memories: memoryTexts.isEmpty ? nil : memoryTexts,
                environmentSummary: latestEnvironmentSummary
            )
            let history = await MainActor.run { historyMessages }
            var finalReply = ""

            await MainActor.run {
                isTyping = true
                streamingText = ""
            }

            // 3. 调用 LLM（优先真实，失败自动回退 Mock）
            do {
                let service = activeLLMService
                finalReply = try await service.sendMessageStreaming(
                    systemPrompt: systemPrompt,
                    history: history,
                    userMessage: userText,
                    imageBase64: nil
                ) { token in
                    Task { @MainActor in
                        if streamingText == nil { streamingText = "" }
                        streamingText? += token
                    }
                }
            } catch {
                // 特殊处理：服务端返回 403 & LIMIT_REACHED，用于每日次数耗尽提示
                if case let LLMError.httpError(statusCode, body) = error,
                   statusCode == 403,
                   body.contains("LIMIT_REACHED") {
                    await MainActor.run {
                        isTyping = false
                        streamingText = nil
                        isSending = false
                        showStaminaDepletedSheet = true
                    }

                    AnalyticsService.shared.trackEvent(
                        "chat_limit_reached",
                        props: [
                            "pet_id": pet.id.uuidString,
                            "pet_name": pet.name
                        ]
                    )
                    return
                }

                print("LLM 调用失败，回退到 Mock: \(error)")
                let mock = MockLLMService()
                do {
                    finalReply = try await mock.sendMessage(systemPrompt: systemPrompt, history: history, userMessage: userText)
                } catch {
                    finalReply = "*垂耳* 我好像暂时连不上大脑了，稍后再试试好吗？"
                }
            }

            let decoded = decodePetReply(from: finalReply)

            // 4. 保存宠物回复
            await MainActor.run {
                let petMessage = ChatMessage(role: .pet, content: decoded.text, pet: pet)
                petMessage.audioURLString = decoded.audioURL
                context.insert(petMessage)
                do {
                    try context.save()
                } catch {
                    print("保存宠物对话失败: \(error)")
                }

                isTyping = false
                streamingText = nil
                isSending = false
                // 新消息到来时自动保证最新对话被加载
                loadedMessageCount = max(loadedMessageCount, displayedMessages.count + 2)

                if voiceAutoPlay,
                   let urlString = decoded.audioURL,
                   let url = URL(string: urlString) {
                    audioManager.play(url: url, for: petMessage.id)
                }
            }

            // 估算 Token 数量（粗略，以字符长度近似）
            let estimatedTokens = (userText.count + decoded.text.count) / 4
            AnalyticsService.shared.trackEvent(
                "llm_reply_completed",
                props: [
                    "pet_id": pet.id.uuidString,
                    "pet_name": pet.name,
                    "estimated_tokens": estimatedTokens
                ]
            )

            // 5. 在后台尝试抽取长期记忆
            let baseURL = URL(string: llmBaseURLString)
            let apiKey = llmAPIKey
            let modelName = llmModelName
            let allMessages = await MainActor.run { allMessagesForCurrentPet }

            Task {
                await MemoryService.shared.extractMemoriesIfNeeded(
                    for: pet,
                    messages: allMessages,
                    llmBaseURL: baseURL,
                    apiKey: apiKey,
                    modelName: modelName,
                    in: context
                )
            }
        }
    }

    // MARK: - 全双工语音模式控制

    private func toggleFullDuplexMode() {
        guard authService.isLoggedIn else {
            showLoginAlert = true
            return
        }

        if isFullDuplexModeOn {
            voiceInteractionService.stop()
            isFullDuplexModeOn = false
        } else {
            voiceInteractionService.start()
            isFullDuplexModeOn = true
        }
    }

    /// 当对话超过 20 条时，将最早 10 条压缩为一段 system 摘要
    private func summarizeIfNeeded() async {
        await MainActor.run {
            let all = allMessagesForCurrentPet
            let nonSystem = all.filter { $0.role != .system }
            guard nonSystem.count > 20 else { return }

            // 简化实现：若已有 system 摘要，则暂不重复聚合
            guard !all.contains(where: { $0.role == .system }) else { return }

            let toSummarize = Array(nonSystem.prefix(10))
            var lines: [String] = []
            for item in toSummarize {
                let speaker = (item.role == .user) ? "你" : pet.name
                lines.append("\(speaker)：\(item.content)")
            }

            let summaryText = "记忆摘要：\n" + lines.joined(separator: "\n")
            let summary = ChatMessage(role: .system, content: summaryText, pet: pet)
            context.insert(summary)

            toSummarize.forEach { context.delete($0) }

            do {
                try context.save()
            } catch {
                print("保存记忆摘要失败: \(error)")
            }
        }
    }

    /// 下拉刷新时尝试加载更早的历史记录
    private func loadMoreHistoryIfPossible() async {
        await MainActor.run {
            let allVisible = allMessagesForCurrentPet.filter { $0.role != .system }
            guard !allVisible.isEmpty else { return }

            let total = allVisible.count
            guard loadedMessageCount < total else { return }

            // 每次多加载 30 条，直至全部加载完
            loadedMessageCount = min(total, loadedMessageCount + 30)
        }
    }

    /// 尝试将 LLM 返回内容解析为带 audio_url 的 JSON 结构；失败则退回为纯文本
    private func decodePetReply(from raw: String) -> (text: String, audioURL: String?) {
        struct Payload: Decodable {
            let text: String
            let audio_url: String?
        }

        guard let data = raw.data(using: .utf8) else {
            return (raw, nil)
        }

        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            return (payload.text, payload.audio_url)
        } else {
            return (raw, nil)
        }
    }

    // MARK: - 天气刷新

    /// 尝试刷新当前天气描述，仅在定位授权允许的情况下生效。
    private func refreshWeatherIfPossible() async -> String? {
        do {
            let description = try await AppWeatherService.shared.fetchCurrentWeatherDescription()
            await MainActor.run {
                latestWeatherDescription = description
            }
            return description
        } catch WeatherServiceError.locationDenied {
            // 用户拒绝定位时，静默忽略，不打断对话。
            return nil
        } catch {
            // 其它天气/网络错误也静默处理，避免影响主流程。
            print("获取天气失败: \(error)")
            return latestWeatherDescription
        }
    }

    // MARK: - 日程获取

    /// 从系统日历与提醒中读取今天的日程摘要，用于注入系统 Prompt
    private func fetchTodayScheduleSummary() async -> String? {
        do {
            return try await CalendarService.shared.fetchTodayScheduleSummary()
        } catch {
            // 用户拒绝授权或系统不支持时，静默降级
            print("获取日程失败: \(error)")
            return nil
        }
    }
}

/// 单条气泡
private struct ChatBubbleView: View {
    let message: ChatMessage
    let pet: Pet

    @ObservedObject var audioManager: AudioPlayerManager

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .pet {
                avatar
            } else {
                Spacer(minLength: 0)
            }

            VStack(alignment: message.role == .pet ? .leading : .trailing, spacing: 6) {
                // 图片预览气泡
                if let data = message.imageData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 220, maxHeight: 260)
                        .clipped()
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.25), radius: 14, x: 0, y: 6)
                }

                // 语音播放气泡（仅宠物消息）
                if message.role == .pet,
                   let url = message.audioURL {
                    VoiceMessageBubble(
                        isCurrent: audioManager.currentMessageID == message.id,
                        isPlaying: audioManager.isPlaying && audioManager.currentMessageID == message.id
                    ) {
                        audioManager.play(url: url, for: message.id)
                    }
                }

                Text(message.content)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .foregroundStyle(bubbleForeground)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if message.role == .user {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .pet ? .leading : .trailing)
    }

    private var avatar: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 32, height: 32)
            .overlay(
                Text(String(pet.name.prefix(1)))
                    .font(.footnote)
                    .foregroundStyle(.white)
            )
    }

    private var bubbleBackground: some ShapeStyle {
        message.role == .pet ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.blue)
    }

    private var bubbleForeground: Color {
        message.role == .pet ? Color.primary : Color.white
    }
}

/// 宠物端的流式回复气泡（含「打字中」动画）
private struct StreamingBubbleView: View {
    let text: String
    let pet: Pet

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 32, height: 32)
                .overlay(
                    Text(String(pet.name.prefix(1)))
                        .font(.footnote)
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                if text.isEmpty {
                    TypingIndicatorBubble()
                } else {
                    Text(text)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Text("正在思考…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 三个点跳动的「打字中」loading 气泡
private struct TypingIndicatorBubble: View {
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 6, height: 6)
                    .scaleEffect(scale(for: index))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = .pi * 2
            }
        }
    }

    private func scale(for index: Int) -> CGFloat {
        let offset = Double(index) * (.pi / 3)
        let v = 0.8 + 0.4 * sin(phase + offset)
        return CGFloat(max(0.6, v))
    }
}

// MARK: - 语音播放管理与波形 UI

/// 简单的音频播放管理器，支持单条消息语音播放与状态同步
final class AudioPlayerManager: ObservableObject {
    @Published var currentMessageID: UUID?
    @Published var isPlaying: Bool = false

    private var player: AVPlayer?
    private var endObserver: Any?

    func play(url: URL, for messageID: UUID) {
        // 再次点击当前正在播放的消息则暂停
        if currentMessageID == messageID, isPlaying {
            pause()
            return
        }

        currentMessageID = messageID

        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)

        // 移除旧的结束监听
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }

        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }
}

/// 「正在发声…」语音气泡 + 动态波形
private struct VoiceMessageBubble: View {
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text(isPlaying ? "正在发声…" : "播放宠物语音")
                        .font(.caption)
                        .foregroundStyle(.primary)

                    VoiceWaveView(isActive: isPlaying)
                        .frame(height: 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(isCurrent ? 0.7 : 0.35), lineWidth: isCurrent ? 1.5 : 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

/// 简化版动态波形视图，用于表达「正在发声」的感觉
private struct VoiceWaveView: View {
    let isActive: Bool
    @State private var phase: Double = 0

    private let barCount = 5

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { idx in
                Capsule(style: .continuous)
                    .fill(Color.blue.opacity(0.8))
                    .frame(width: 4, height: barHeight(for: idx))
            }
        }
        .onAppear {
            guard isActive else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                phase = .pi * 2
            }
        }
        .onChange(of: isActive) { active in
            if active {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    phase = .pi * 2
                }
            } else {
                phase = 0
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard isActive else { return 6 }
        let offset = Double(index) * (.pi / Double(barCount))
        let value = 6 + 6 * (1 + sin(phase + offset))
        return CGFloat(value)
    }
}

// MARK: - 记忆透明化视图

/// 顶部「我的记忆」入口，采用毛玻璃 + 2.5D 卡片风格
private struct MemoryEntryView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 4) {
                Text("我的记忆")
                    .font(.footnote.weight(.semibold))

                Text(text)
                    .font(.caption2)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 6)
    }
}

/// 展示历史记忆摘要的弹窗视图
private struct MemoryDetailView: View {
    let memories: [MemoryEntry]
    let pet: Pet

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if memories.isEmpty {
                        Text("当前还没有形成长期记忆，和宠物多聊聊吧～")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    } else {
                        ForEach(memories, id: \.id) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.timestamp, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                Text(item.content)
                                    .font(.subheadline)
                            }
                            .padding(12)
                            .background(
                                .ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("\(pet.name) 的记忆")
            .navigationBarTitleDisplayMode(.inline)
            .background(.thinMaterial)
        }
    }
}
