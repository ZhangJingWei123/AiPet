import Foundation
import Security
import Combine
import StoreKit

/// 全局认证服务：负责登录态管理与 Token 安全存储
@MainActor
final class AuthService: ObservableObject {
    // MARK: - Singleton

    static let shared = AuthService()

    // MARK: - 公共状态

    /// 是否已登录（根据本地 JWT Token 有效性推导）
    @Published private(set) var isLoggedIn: Bool = false

    /// 当前 JWT Token（仅在内存中使用，不对外暴露可写）
    @Published private(set) var jwtToken: String?

    /// 当前是否为 AIPet Plus 会员（原始会员标记，不含过期校验）
    @Published private(set) var isPlusMember: Bool = false

    /// Plus 会员是否在有效期内（服务端校验结果）
    @Published private(set) var isPlusActive: Bool = false

    /// Plus 会员到期时间（如果有）
    @Published private(set) var plusExpiresAt: Date?

    /// 最近一次支付错误信息（可选，便于 UI 展示）
    @Published var lastPurchaseErrorMessage: String?

    /// 正在进行网络请求
    @Published var isLoading: Bool = false

    /// 最近一次错误信息（便于 UI 展示）
    @Published var errorMessage: String?

    /// 最近一次注册到的推送 deviceToken（APNs），登录后会自动上报后端
    @Published private(set) var pushDeviceToken: String?

    // MARK: - 配置

    private let apiBaseURL: URL = {
        if let v = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
           let url = URL(string: v.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil {
            return url
        }
        return URL(string: "https://aipet-is7f.onrender.com")!
    }()

    private let apiV1PathPrefix = "v1"

    private func apiURL(path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return apiBaseURL.appendingPathComponent(apiV1PathPrefix).appendingPathComponent(trimmed)
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            if let urlError = error as? URLError {
                let host = request.url?.host ?? apiBaseURL.host ?? ""
                switch urlError.code {
                case .cannotFindHost:
                    errorMessage = "无法解析服务器域名（\(host)），请检查网络或稍后重试。"
                case .cannotConnectToHost:
                    errorMessage = "无法连接服务器（\(host)），请检查网络或稍后重试。"
                case .timedOut:
                    errorMessage = "连接服务器超时（\(host)），请稍后重试。"
                case .notConnectedToInternet:
                    errorMessage = "当前网络不可用，请检查网络连接后重试。"
                default:
                    errorMessage = urlError.localizedDescription
                }
            } else {
                errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    private let keychainService = "com.aipet.app.auth"
    private let tokenKey = "jwt_token"

    /// StoreKit 2 相关配置
    enum PlusPlan {
        case monthly
        case yearly
    }

    private let appAccountTokenUserDefaultsKey = "aipet_app_account_token"
    /// 提交给 App Store 的 appAccountToken，用于将交易与应用账号绑定
    private(set) var appAccountToken: UUID = AuthService.loadOrCreateAppAccountToken()

    /// StoreKit 交易更新监听任务
    private var transactionListenerTask: Task<Void, Never>?

    private init() {
        loadTokenFromKeychain()

        // 启动后如果已有有效 Token，后台刷新一次会员信息
        if isLoggedIn {
            Task {
                await self.refreshMembershipStatus()
                await self.syncCurrentStoreKitEntitlementsIfNeeded()
            }
        }

        // 无论登录状态如何，监听 StoreKit 交易更新，保证离线购买和续费能回传
        observeStoreKitTransactionUpdates()
    }

    // MARK: - 对外接口

    /// Apple 登录
    func loginWithApple(identityToken: String) async throws {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        struct RequestBody: Encodable { let identityToken: String }

        struct ResponseBody: Decodable {
            let accessToken: String
            let tokenType: String
            let expiresIn: Int64
        }

        let url = apiURL(path: "/auth/apple")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(identityToken: identityToken))

        let (data, response) = try await data(for: request)
        try handleCommonHTTPError(response: response, data: data)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ResponseBody.self, from: data)
        try persistToken(decoded.accessToken)
    }

    /// 发送手机验证码
    func sendSMSCode(phoneNumber: String) async throws {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        struct RequestBody: Encodable { let phoneNumber: String }

        let url = apiURL(path: "/auth/sms/send")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(RequestBody(phoneNumber: phoneNumber))

        let (data, response) = try await data(for: request)
        try handleCommonHTTPError(response: response, data: data)

        // 一般只需要确认 200 / 204 即可，这里不解析内容
        _ = data
    }

    /// 校验手机验证码并完成登录
    func verifySMSCode(phoneNumber: String, code: String) async throws {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        struct RequestBody: Encodable {
            let phoneNumber: String
            let code: String
        }

        struct ResponseBody: Decodable {
            let accessToken: String
            let tokenType: String
            let expiresIn: Int64
        }

        let url = apiURL(path: "/auth/sms/verify")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(RequestBody(phoneNumber: phoneNumber, code: code))

        let (data, response) = try await data(for: request)
        try handleCommonHTTPError(response: response, data: data)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ResponseBody.self, from: data)
        try persistToken(decoded.accessToken)
    }

    /// 主动注销
    func logout() {
        clearToken()
    }

    // MARK: - StoreKit 2 真实支付

    /// 触发 AIPet Plus 订阅/续费（StoreKit 2）
    func purchasePlus(plan: PlusPlan) async throws {
        errorMessage = nil
        lastPurchaseErrorMessage = nil
        isLoading = true
        defer { isLoading = false }

        let productID = productIdentifier(for: plan)

        let product: Product
        do {
            product = try await fetchProduct(withID: productID)
        } catch {
            lastPurchaseErrorMessage = "拉取商品信息失败：" + error.localizedDescription
            throw error
        }

        do {
            let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
            try await handlePurchaseResult(result)
        } catch {
            // 用户手动取消不视为错误
            if error is CancellationError {
                return
            }
            if let skError = error as? StoreKitError {
                if case StoreKitError.userCancelled = skError {
                    return
                }
            }
            lastPurchaseErrorMessage = "发起购买失败：" + error.localizedDescription
            throw error
        }
    }

    /// 供外部接口调用时使用的授权请求构建
    func authorizedRequest(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let token = jwtToken, !isTokenExpired(token) else {
            clearToken()
            throw AuthError.tokenExpired
        }

        let url = apiURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - 内部逻辑

    private func loadTokenFromKeychain() {
        jwtToken = try? readTokenFromKeychain()
        if let token = jwtToken, !isTokenExpired(token) {
            isLoggedIn = true
            // 尝试同步会员状态（异步，不阻塞启动）
            Task {
                await self.refreshMembershipStatus()
            }
        } else {
            clearToken()
        }
    }

    /// 将 APNs 的 deviceToken 记录在内存，并在可能时尝试上报后端
    func updatePushDeviceToken(_ token: String) {
        pushDeviceToken = token

        Task {
            await self.syncPushTokenIfNeeded()
        }
    }

    private func persistToken(_ token: String) throws {
        try saveTokenToKeychain(token)
        jwtToken = token
        if isTokenExpired(token) {
            clearToken()
            throw AuthError.tokenExpired
        }
        isLoggedIn = true
        // 登录成功后刷新一次会员状态，并同步 StoreKit 权益
        Task {
            await self.refreshMembershipStatus()
            await self.syncCurrentStoreKitEntitlementsIfNeeded()
        }
    }

    private func clearToken() {
        deleteTokenFromKeychain()
        jwtToken = nil
        isLoggedIn = false
        NotificationCenter.default.post(name: .authDidLogout, object: nil)
    }

    private func handleCommonHTTPError(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }

        if http.statusCode == 401 {
            clearToken()
            throw AuthError.unauthorized
        }

        let serverMessage: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            serverMessage = message
        } else {
            serverMessage = nil
        }

        let error = AuthError.serverError(code: http.statusCode, message: serverMessage)
        errorMessage = serverMessage
        throw error
    }

    // MARK: - JWT 过期判断（基于 exp 字段）

    private func isTokenExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return false }

        let payloadPart = parts[1]
        var base64 = String(payloadPart)
        // JWT Base64url -> Base64
        base64 = base64.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return false
        }

        let expireDate = Date(timeIntervalSince1970: exp)
        return expireDate <= Date()
    }

    // MARK: - Keychain 封装

    private func saveTokenToKeychain(_ token: String) throws {
        let data = Data(token.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenKey
        ]

        SecItemDelete(query as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenKey,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.keychainError(status: status)
        }
    }

    private func readTokenFromKeychain() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenKey,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw AuthError.keychainError(status: status)
        }

        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw AuthError.invalidTokenFormat
        }

        return token
    }

    private func deleteTokenFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenKey
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - StoreKit 2 内部工具

    private static func loadOrCreateAppAccountToken() -> UUID {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "aipet_app_account_token"),
           let uuid = UUID(uuidString: raw) {
            return uuid
        }

        let uuid = UUID()
        defaults.set(uuid.uuidString, forKey: "aipet_app_account_token")
        return uuid
    }

    private func productIdentifier(for plan: PlusPlan) -> String {
        switch plan {
        case .monthly:
            return "aipet.plus.monthly"
        case .yearly:
            return "aipet.plus.yearly"
        }
    }

    private func fetchProduct(withID identifier: String) async throws -> Product {
        let products = try await Product.products(for: [identifier])
        if let product = products.first {
            return product
        }
        throw AuthError.serverError(code: -1, message: "未找到对应的内购商品：\(identifier)")
    }

    private func handlePurchaseResult(_ result: Product.PurchaseResult) async throws {
        switch result {
        case .success(let verification):
            try await handleTransactionVerification(verification)
        case .userCancelled:
            // 用户取消不做处理
            break
        case .pending:
            // 等待中状态由后续 Transaction.updates 继续处理
            break
        @unknown default:
            break
        }
    }

    private func handleTransactionVerification(_ verification: VerificationResult<Transaction>) async throws {
        switch verification {
        case .unverified(_, let error):
            let message = error.localizedDescription
            lastPurchaseErrorMessage = message
            throw AuthError.serverError(code: -2, message: message)
        case .verified(let transaction):
            await syncStoreKitTransactionToBackend(transaction)
            await transaction.finish()
        }
    }

    private func observeStoreKitTransactionUpdates() {
        transactionListenerTask?.cancel()
        transactionListenerTask = Task { [weak self] in
            guard let self else { return }
            for await verification in Transaction.updates {
                do {
                    try await self.handleTransactionVerification(verification)
                } catch {
                    print("处理 StoreKit 交易更新失败: \(error)")
                }
            }
        }
    }

    /// App 冷启动或重新登录后，同步当前有效订阅到后端
    private func syncCurrentStoreKitEntitlementsIfNeeded() async {
        guard jwtToken != nil else { return }

        do {
            for await verification in Transaction.currentEntitlements {
                do {
                    try await handleTransactionVerification(verification)
                } catch {
                    print("同步当前 StoreKit 权益失败: \(error)")
                }
            }
        } catch {
            print("遍历当前 StoreKit 权益失败: \(error)")
        }
    }

    /// 将 StoreKit 交易信息回传给后端，让服务端做最终订阅判断
    private func syncStoreKitTransactionToBackend(_ transaction: Transaction) async {
        guard jwtToken != nil else { return }

        struct Payload: Encodable {
            let appAccountToken: UUID
            let productID: String
            let transactionID: String
            let originalTransactionID: String
            let purchaseDate: Date
        }

        let payload = Payload(
            appAccountToken: appAccountToken,
            productID: transaction.productID,
            transactionID: String(transaction.id),
            originalTransactionID: String(transaction.originalID),
            purchaseDate: transaction.purchaseDate
        )

        do {
            let body = try JSONEncoder().encode(payload)
            let request = try authorizedRequest(
                path: "/v1/membership/storekit2/confirm",
                method: "POST",
                body: body
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            try handleCommonHTTPError(response: response, data: data)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let status = try decoder.decode(MembershipStatusResponse.self, from: data)

            isPlusMember = status.isPlusMember
            isPlusActive = status.isPlusActive
            plusExpiresAt = status.plusExpiresAt
        } catch {
            print("同步 StoreKit 交易到后端失败: \(error)")
        }
    }

    // MARK: - 推送 Token 同步

    private func syncPushTokenIfNeeded() async {
        guard let token = pushDeviceToken, jwtToken != nil else { return }

        struct Payload: Encodable {
            let deviceToken: String
        }

        do {
            let body = try JSONEncoder().encode(Payload(deviceToken: token))
            let request = try authorizedRequest(path: "/v1/push/register", method: "POST", body: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            try handleCommonHTTPError(response: response, data: data)
            _ = data
        } catch {
            print("上报推送 deviceToken 失败: \(error)")
        }
    }

    // MARK: - 会员相关接口（依赖已登录状态）

    /// 从后端查询当前用户的会员状态，并刷新内存中的 Plus 信息
    func refreshMembershipStatus() async {
        // 未登录时重置本地状态
        guard jwtToken != nil else {
            isPlusMember = false
            isPlusActive = false
            plusExpiresAt = nil
            return
        }

        do {
            let request = try authorizedRequest(path: "/v1/membership/status")
            let (data, response) = try await URLSession.shared.data(for: request)
            try handleCommonHTTPError(response: response, data: data)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let status = try decoder.decode(MembershipStatusResponse.self, from: data)

            isPlusMember = status.isPlusMember
            isPlusActive = status.isPlusActive
            plusExpiresAt = status.plusExpiresAt
        } catch {
            // 查询失败时不打断主流程，只记录错误信息
            print("刷新会员状态失败: \(error)")
        }
    }

    /// Mock 订阅 / 续费 AIPet Plus：调用后端的 mock 升级接口
    func mockUpgradePlus(durationDays: Int) async throws {
        guard durationDays > 0 else { return }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        let body = try JSONEncoder().encode(MockUpgradeRequest(durationDays: durationDays))
        var request = try authorizedRequest(path: "/v1/membership/mock_upgrade_plus", method: "POST", body: body)
        // `authorizedRequest` 已经设置 Content-Type

        let (data, response) = try await URLSession.shared.data(for: request)
        try handleCommonHTTPError(response: response, data: data)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(MockUpgradeResponse.self, from: data)

        if result.success {
            isPlusMember = result.isPlusMember
            isPlusActive = true
            plusExpiresAt = result.plusExpiresAt
        }
    }
}

// MARK: - 会员接口 DTO

private struct MembershipStatusResponse: Decodable {
    let isPlusMember: Bool
    let plusExpiresAt: Date?
    let isPlusActive: Bool

    enum CodingKeys: String, CodingKey {
        case isPlusMember = "is_plus_member"
        case plusExpiresAt = "plus_expires_at"
        case isPlusActive = "is_plus_active"
    }
}

private struct MockUpgradeRequest: Encodable {
    let durationDays: Int

    enum CodingKeys: String, CodingKey {
        case durationDays = "duration_days"
    }
}

private struct MockUpgradeResponse: Decodable {
    let success: Bool
    let isPlusMember: Bool
    let plusExpiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case success
        case isPlusMember = "is_plus_member"
        case plusExpiresAt = "plus_expires_at"
    }
}


// MARK: - 错误类型与通知

enum AuthError: LocalizedError {
    case unauthorized
    case tokenExpired
    case serverError(code: Int, message: String?)
    case keychainError(status: OSStatus)
    case invalidTokenFormat

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "未授权或登录已失效，请重新登录。"
        case .tokenExpired:
            return "登录已过期，请重新登录。"
        case let .serverError(code, message):
            if let message = message { return message }
            return "服务器错误（\(code)）。"
        case let .keychainError(status):
            return "Keychain 存取失败（status=\(status)）。"
        case .invalidTokenFormat:
            return "无效的 Token 格式。"
        }
    }
}

extension Notification.Name {
    /// 当登录态失效或主动注销时发送
    static let authDidLogout = Notification.Name("AuthDidLogout")

    /// 用户点击推送通知时发送（userInfo 中透传原始 payload）
    static let pushNotificationTapped = Notification.Name("PushNotificationTapped")
}
