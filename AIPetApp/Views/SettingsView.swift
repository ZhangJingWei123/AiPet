import SwiftUI

/// LLM 配置页：允许用户设置 Base URL / API Key / Model，并测试连接
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var authService: AuthService

    @AppStorage("llm_base_url") private var llmBaseURLString: String = "https://api.openai.com"
    @AppStorage("llm_api_key") private var llmAPIKey: String = ""
    @AppStorage("llm_model_name") private var llmModelName: String = "gpt-4.1-mini"

    /// 语音自动播放开关
    @AppStorage("voice_auto_play") private var voiceAutoPlay: Bool = false

    @State private var isTesting: Bool = false
    @State private var testMessage: String = "你能听到我说话吗？"
    @State private var testResult: String?
    @State private var testError: String?

    @State private var isPresentingPlusSheet: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("账户 · 会员")) {
                    Button {
                        if authService.isLoggedIn {
                            isPresentingPlusSheet = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "crown.fill")
                                .foregroundStyle(.yellow)
                            Text("我的订阅")
                            Spacer()

                            if authService.isPlusActive, let expire = authService.plusExpiresAt {
                                Text("Plus · 到期：" + dateFormatter.string(from: expire))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if authService.isLoggedIn {
                                Text("未开通")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("未登录")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section(header: Text("LLM 服务配置")) {
                    TextField("Base URL", text: $llmBaseURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("API Key", text: $llmAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Model Name", text: $llmModelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section(header: Text("语音交互")) {
                    Toggle("语音自动播放", isOn: $voiceAutoPlay)

                    Text("开启后，当宠物回复中包含语音时，将在聊天界面自动播放对应语音。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("测试连接"), footer: footerView) {
                    TextField("测试消息", text: $testMessage, axis: .vertical)
                        .lineLimit(1...3)

                    Button {
                        runConnectionTest()
                    } label: {
                        if isTesting {
                            HStack {
                                ProgressView()
                                Text("正在测试…")
                            }
                        } else {
                            Text("测试连接")
                        }
                    }
                    .disabled(isTesting)
                }
            }
            .navigationTitle("LLM 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $isPresentingPlusSheet) {
                AIPetPlusView(source: .generic)
                    .environmentObject(authService)
            }
        }
    }

    @ViewBuilder
    private var footerView: some View {
        if let testResult {
            VStack(alignment: .leading, spacing: 4) {
                Text("连接成功")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(testResult)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } else if let testError {
            VStack(alignment: .leading, spacing: 4) {
                Text("连接失败")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(testError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } else {
            Text("点击上方按钮，将向当前配置的 LLM 发送一条简单问候，用于验证 Base URL / API Key / Model 是否可用。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var dateFormatter: DateFormatter {
        AIPetPlusView.dateFormatter
    }

    private func runConnectionTest() {
        testResult = nil
        testError = nil

        let trimmedKey = llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = llmBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = llmModelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedKey.isEmpty else {
            testError = "请先填写 API Key。"
            return
        }

        guard !trimmedModel.isEmpty else {
            testError = "请先填写模型名称。"
            return
        }

        guard let baseURL = URL(string: trimmedURL) else {
            testError = "Base URL 无效，请检查格式。"
            return
        }

        isTesting = true

        Task {
            let config = LLMConfig(baseURL: baseURL, apiKey: trimmedKey, model: trimmedModel)
            let service = OpenAICompatibleLLMService(config: config)

            do {
                let reply = try await service.sendMessage(
                    systemPrompt: "你是一只友好的虚拟宠物，正在执行连通性自检。",
                    history: [],
                    userMessage: testMessage
                )

                await MainActor.run {
                    isTesting = false
                    if reply.isEmpty {
                        testResult = "请求成功，但模型没有返回内容。"
                    } else {
                        let preview = reply.prefix(80)
                        testResult = String(preview) + (reply.count > 80 ? "…" : "")
                    }
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    if let llmError = error as? LLMError {
                        switch llmError {
                        case let .httpError(status, body):
                            testError = "HTTP 错误 (\(status))：\(body)"
                        }
                    } else {
                        testError = error.localizedDescription
                    }
                }
            }
        }
    }
}
