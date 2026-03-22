import Foundation

/// 统一埋点上报服务
///
/// iOS 侧只做 best-effort 异步上报，失败不会打断业务流程。
@MainActor
final class AnalyticsService {
    static let shared = AnalyticsService()

    private init() {}

    /// 业务事件上报入口
    /// - Parameters:
    ///   - name: 事件名，如 `chat_send`, `llm_reply_completed`, `plus_purchase_success` 等
    ///   - props: 事件属性，支持 String / Int / Double / Bool / [String: Any] / [Any]
    func trackEvent(_ name: String, props: [String: Any] = [:], platform: String = "ios") {
        guard !name.isEmpty else { return }

        // 未登录时不强制要求带上用户信息，后端可按需接受匿名事件
        Task.detached { @MainActor in
            do {
                struct Payload: Encodable {
                    let event_name: String
                    let properties: [String: AnyEncodable]?
                    let platform: String
                }

                let encodableProps = props.mapValues { AnyEncodable($0) }
                let body = try JSONEncoder().encode(
                    Payload(
                        event_name: name,
                        properties: encodableProps.isEmpty ? nil : encodableProps,
                        platform: platform
                    )
                )

                let request = try AuthService.shared.authorizedRequest(
                    path: "/v1/events/track",
                    method: "POST",
                    body: body
                )

                _ = try await URLSession.shared.data(for: request)
            } catch {
                // 埋点失败仅记录日志，避免影响主流程
                print("[Analytics] trackEvent failed: \(error)")
            }
        }
    }
}

/// 动态类型到 JSON 的轻量包装器
struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void

    init(_ value: Any) {
        if let v = value as? Encodable {
            self.encodeFunc = { encoder in
                var container = encoder.singleValueContainer()

                switch v {
                case let s as String: try container.encode(s)
                case let i as Int: try container.encode(i)
                case let d as Double: try container.encode(d)
                case let b as Bool: try container.encode(b)
                case let f as Float: try container.encode(f)
                case let arr as [Any]:
                    try container.encode(arr.map { AnyEncodable($0) })
                case let dict as [String: Any]:
                    try container.encode(dict.mapValues { AnyEncodable($0) })
                default:
                    // 其他类型统一转字符串
                    try container.encode(String(describing: v))
                }
            }
        } else {
            self.encodeFunc = { encoder in
                var container = encoder.singleValueContainer()
                try container.encode(String(describing: value))
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}

