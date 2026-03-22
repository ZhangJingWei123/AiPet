import Foundation

// MARK: - 公共消息模型

/// LLM 对话消息模型，兼容 OpenAI Chat 格式
struct LLMChatMessage: Sendable {
    enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    var role: Role
    var content: String

    var apiRole: String { role.rawValue }
}

// MARK: - 配置与协议

/// LLM 基础配置
struct LLMConfig: Sendable {
    var baseURL: URL
    var apiKey: String
    var model: String
}

/// 统一的 LLM 抽象
protocol LLMService: Sendable {
    /// 非流式：发送一轮消息，得到完整回复
    func sendMessage(
        systemPrompt: String,
        history: [LLMChatMessage],
        userMessage: String
    ) async throws -> String

    /// 流式：逐 token 回调 + 返回最终完整回复
    /// - Parameters:
    ///   - systemPrompt: 本轮对话的系统提示词
    ///   - history: 之前的消息历史
    ///   - userMessage: 当前用户输入的文本
    ///   - imageBase64: 可选的 base64 图片数据，用于多模态（视觉）输入
    ///   - onToken: 每次增量返回的文本片段回调
    func sendMessageStreaming(
        systemPrompt: String,
        history: [LLMChatMessage],
        userMessage: String,
        imageBase64: String?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

extension LLMService {
    /// 默认的流式实现：基于完整回复做打字机拆分
    func sendMessageStreaming(
        systemPrompt: String,
        history: [LLMChatMessage],
        userMessage: String,
        imageBase64: String? = nil,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        // 默认实现忽略 imageBase64，仅做文本拆分
        _ = imageBase64
        let full = try await sendMessage(systemPrompt: systemPrompt, history: history, userMessage: userMessage)
        for ch in full {
            onToken(String(ch))
            try await Task.sleep(nanoseconds: 40_000_000) // 40ms 打字效果
        }
        return full
    }
}

// MARK: - OpenAI 兼容实现

/// OpenAI Chat Completions 兼容实现，支持任意 Base URL + API Key + Model
struct OpenAICompatibleLLMService: LLMService {
    let config: LLMConfig
    private let urlSession: URLSession

    init(config: LLMConfig, session: URLSession = .shared) {
        self.config = config
        self.urlSession = session
    }

    // 非流式兜底（服务端不支持 stream 时可复用）
    func sendMessage(
        systemPrompt: String,
        history: [LLMChatMessage],
        userMessage: String
    ) async throws -> String {
        let request = try makeRequest(
            systemPrompt: systemPrompt,
            history: history,
            userMessage: userMessage,
            imageBase64: nil,
            stream: false
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "<invalid utf8>"
            throw LLMError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: body)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let content = decoded.choices.first?.message.content ?? ""
        return content
    }

    // 真实流式实现：SSE + streaming: true
    func sendMessageStreaming(
        systemPrompt: String,
        history: [LLMChatMessage],
        userMessage: String,
        imageBase64: String?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let request = try makeRequest(
            systemPrompt: systemPrompt,
            history: history,
            userMessage: userMessage,
            imageBase64: imageBase64,
            stream: true
        )

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let body = try? await bytes.reduce(into: Data()) { partial, chunk in
                partial.append(chunk)
            }
            let bodyString = body.flatMap { String(data: $0, encoding: .utf8) } ?? "<invalid utf8>"
            throw LLMError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: bodyString)
        }

        var fullText = ""
        let decoder = JSONDecoder()

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let dataPart = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if dataPart == "[DONE]" { break }

            guard let jsonData = dataPart.data(using: .utf8) else { continue }

            do {
                let chunk = try decoder.decode(ChatCompletionChunk.self, from: jsonData)
                for choice in chunk.choices {
                    if let delta = choice.delta.content, !delta.isEmpty {
                        fullText += delta
                        onToken(delta)
                    }
                }
            } catch {
                // 忽略单个 chunk 解码错误，避免整次对话失败
                continue
            }
        }

        return fullText
    }

    // MARK: - 请求构建

    private func makeRequest(
        systemPrompt: String,
        history: [LLMChatMessage],
        userMessage: String,
        imageBase64: String?,
        stream: Bool
    ) throws -> URLRequest {
        var url = config.baseURL
        if url.path.isEmpty || url.path == "/" {
            url.append(path: "/v1/chat/completions")
        } else {
            url.append(path: "v1/chat/completions")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        // 构造多模态兼容的 messages：
        // - system / history 仍然是纯文本；
        // - 当前 user 消息在存在 imageBase64 时，使用 "text + image_url" 的多段 content。
        var messagesPayload: [ChatCompletionRequest.Message] = []
        messagesPayload.append(.init(role: LLMChatMessage.Role.system.rawValue, content: [.text(systemPrompt)]))
        for msg in history {
            messagesPayload.append(.init(role: msg.apiRole, content: [.text(msg.content)]))
        }

        if let imageBase64, !imageBase64.isEmpty {
            let imageURL = "data:image/jpeg;base64,\(imageBase64)"
            let contents: [ChatCompletionRequest.Message.Content] = [
                .text(userMessage),
                .imageURL(imageURL)
            ]
            messagesPayload.append(.init(role: LLMChatMessage.Role.user.rawValue, content: contents))
        } else {
            messagesPayload.append(.init(role: LLMChatMessage.Role.user.rawValue, content: [.text(userMessage)]))
        }

        let payload = ChatCompletionRequest(
            model: config.model,
            messages: messagesPayload,
            stream: stream
        )

        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }
}

// MARK: - Mock 实现

/// 无网络 / 无配置时的本地 Mock
struct MockLLMService: LLMService {
    func sendMessage(
        systemPrompt: String,
        history: [LLMChatMessage],
        userMessage: String
    ) async throws -> String {
        let lowerPrompt = systemPrompt.lowercased()
        let isEnergetic = lowerPrompt.contains("活泼") || lowerPrompt.contains("蹦蹦跳跳")
        let isQuiet = lowerPrompt.contains("安静")

        if isEnergetic {
            return "*蹦蹦跳跳地扑过来* 我听到了你说：\(userMessage)！！！好想多跟你聊聊呀！"
        } else if isQuiet {
            return "*悄悄挤在你身边* 我听到了你说：\(userMessage)。我会慢慢地、温柔地陪着你。"
        } else {
            return "*摇摇尾巴* 谢谢你跟我说：\(userMessage)。我会按照现在的性格设定好好回应你～"
        }
    }
}

// MARK: - OpenAI API DTO

enum LLMError: Error {
    case httpError(statusCode: Int, body: String)
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        struct Content: Encodable {
            struct ImageURL: Encodable {
                var url: String
            }

            var type: String
            var text: String?
            var image_url: ImageURL?

            static func text(_ text: String) -> Content {
                .init(type: "text", text: text, image_url: nil)
            }

            static func imageURL(_ url: String) -> Content {
                .init(type: "image_url", text: nil, image_url: .init(url: url))
            }
        }

        var role: String
        var content: [Content]
    }

    var model: String
    var messages: [Message]
    var stream: Bool
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            struct ContentPart: Decodable {
                var type: String
                var text: String?
            }

            var role: String
            var content: String

            private enum CodingKeys: String, CodingKey {
                case role
                case content
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.role = try container.decode(String.self, forKey: .role)

                // OpenAI 新版接口中，content 可能是 String 或 [ContentPart]
                if let text = try? container.decode(String.self, forKey: .content) {
                    self.content = text
                } else if let parts = try? container.decode([ContentPart].self, forKey: .content) {
                    let allText = parts.compactMap { $0.text }.joined()
                    self.content = allText
                } else {
                    self.content = ""
                }
            }
        }

        var index: Int
        var message: Message
        var finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }
    }

    var choices: [Choice]
}

private struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ContentPart: Decodable {
                var type: String
                var text: String?
            }

            var role: String?
            var content: String?

            private enum CodingKeys: String, CodingKey {
                case role
                case content
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.role = try container.decodeIfPresent(String.self, forKey: .role)

                // 流式增量内容同样可能是 String 或 [ContentPart]
                if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
                    self.content = text
                } else if let parts = try? container.decodeIfPresent([ContentPart].self, forKey: .content) {
                    let allText = parts?.compactMap { $0.text }.joined()
                    self.content = allText
                } else {
                    self.content = nil
                }
            }
        }

        var index: Int
        var delta: Delta
        var finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason = "finish_reason"
        }
    }

    var choices: [Choice]
}
