import SwiftUI
import AuthenticationServices

/// 登录页：支持手机号验证码登录与 Apple ID 登录
struct LoginView: View {
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var isPresentingPhoneLogin: Bool = false
    @State private var hasAgreed: Bool = false
    @State private var localErrorMessage: String?

    @StateObject private var appleCoordinator = AppleSignInCoordinator()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1.0, green: 0.72, blue: 0.60).opacity(0.55), Color(red: 0.98, green: 0.52, blue: 0.44).opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 96)

                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color(red: 0.98, green: 0.52, blue: 0.44))
                            .frame(width: 88, height: 88)
                            .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 8)
                        Image("LoginMascot")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                    }

                    Text("AIPet")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Spacer()

                VStack(spacing: 14) {
                    Button {
                        localErrorMessage = nil
                        guard hasAgreed else {
                            localErrorMessage = "请先阅读并同意《用户协议》和《隐私协议》"
                            return
                        }
                        isPresentingPhoneLogin = true
                    } label: {
                        Text("手机号登录")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .background(Color(red: 0.98, green: 0.52, blue: 0.44))
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                    Button {
                        localErrorMessage = nil
                        guard hasAgreed else {
                            localErrorMessage = "请先阅读并同意《用户协议》和《隐私协议》"
                            return
                        }
                        appleCoordinator.startSignIn()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 18, weight: .semibold))
                            Text("通过 Apple 登录")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.75))
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
                    .overlay {
                        if appleCoordinator.isProcessing {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(.thinMaterial)
                            ProgressView()
                        }
                    }
                    .disabled(appleCoordinator.isProcessing || authService.isLoading)

                    agreementRow

                    Text("在 AIPet，遇见懂你的 AI 萌宠。它陪你聊天、记录心情、发现小惊喜，让每一天更轻松有爱，也许下一句话，就是它给你的温柔回应。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)

                    if let message = localErrorMessage ?? authService.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
        }
        .onChange(of: authService.isLoggedIn) { loggedIn in
            if loggedIn {
                dismiss()
            }
        }
        .onAppear {
            appleCoordinator.onIdentityToken = { token in
                Task {
                    do {
                        try await authService.loginWithApple(identityToken: token)
                    } catch {
                        await MainActor.run {
                            authService.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                }
            }
            appleCoordinator.onError = { error in
                authService.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        .sheet(isPresented: $isPresentingPhoneLogin) {
            PhoneLoginSheetView()
                .environmentObject(authService)
        }
    }

    private var agreementRow: some View {
        HStack(spacing: 8) {
            Button {
                hasAgreed.toggle()
            } label: {
                Image(systemName: hasAgreed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(hasAgreed ? Color(red: 0.98, green: 0.52, blue: 0.44) : Color.secondary)
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)

            Text("已阅读并同意")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("《用户协议》") {
                localErrorMessage = "用户协议链接待接入"
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)

            Text("和")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("《隐私协议》") {
                localErrorMessage = "隐私协议链接待接入"
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.top, 2)
    }
}


final class AppleSignInCoordinator: NSObject, ObservableObject {
    @Published var isProcessing: Bool = false
    var onIdentityToken: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private var controller: ASAuthorizationController?

    @MainActor
    func startSignIn() {
        isProcessing = true
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]

        let c = ASAuthorizationController(authorizationRequests: [request])
        c.delegate = self
        c.presentationContextProvider = self
        controller = c
        c.performRequests()
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        defer { isProcessing = false }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            onError?(NSError(domain: "AIPetAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Apple 授权信息无效"]))
            return
        }
        guard let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8), !token.isEmpty else {
            onError?(NSError(domain: "AIPetAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: "未获取到 Apple identityToken"]))
            return
        }
        onIdentityToken?(token)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        isProcessing = false
        onError?(error)
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        return ASPresentationAnchor()
    }
}

struct PhoneLoginSheetView: View {
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var countryCode: String = "+86"
    @State private var phoneNumber: String = ""
    @State private var smsCode: String = ""

    @State private var isSendingCode: Bool = false
    @State private var countdown: Int = 0
    @State private var isVerifyingCode: Bool = false
    @State private var localErrorMessage: String?

    private var e164Phone: String {
        let digitsOnly = phoneNumber.filter { $0.isNumber }
        return countryCode + digitsOnly
    }

    private var isPhoneValid: Bool {
        let digitsOnly = phoneNumber.filter { $0.isNumber }
        switch countryCode {
        case "+86":
            return digitsOnly.count == 11 && digitsOnly.hasPrefix("1")
        case "+1":
            return digitsOnly.count == 10
        case "+81":
            return digitsOnly.count == 10 || digitsOnly.count == 11
        default:
            return !digitsOnly.isEmpty
        }
    }

    private var isCodeValid: Bool {
        smsCode.trimmingCharacters(in: .whitespacesAndNewlines).count == 6
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("手机号登录")
                        .font(.title3.weight(.semibold))

                    HStack(spacing: 10) {
                        Menu {
                            Button("中国 +86") { countryCode = "+86" }
                            Button("美国 +1") { countryCode = "+1" }
                            Button("日本 +81") { countryCode = "+81" }
                        } label: {
                            HStack(spacing: 6) {
                                Text(countryCode)
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        TextField("请输入手机号", text: $phoneNumber)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Text("将以 \(e164Phone) 接收验证码")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        TextField("6 位验证码", text: $smsCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button(action: sendCodeTapped) {
                            if countdown > 0 {
                                Text("重新发送(\(countdown)s)")
                            } else if isSendingCode || authService.isLoading {
                                ProgressView()
                            } else {
                                Text("发送验证码")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(!isPhoneValid || countdown > 0 || isSendingCode || authService.isLoading)
                    }

                    Button(action: verifyCodeTapped) {
                        if isVerifyingCode || authService.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("验证码登录")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.98, green: 0.52, blue: 0.44))
                    .frame(maxWidth: .infinity)
                    .disabled(!isPhoneValid || !isCodeValid || isVerifyingCode || authService.isLoading)

                    if let message = localErrorMessage ?? authService.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer()
            }
            .padding(20)
            .navigationTitle("登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onChange(of: authService.isLoggedIn) { loggedIn in
            if loggedIn {
                dismiss()
            }
        }
    }

    private func sendCodeTapped() {
        localErrorMessage = nil
        guard isPhoneValid, countdown == 0, !isSendingCode else { return }

        let fullPhone = e164Phone
        isSendingCode = true

        Task {
            do {
                try await authService.sendSMSCode(phoneNumber: fullPhone)
                await MainActor.run {
                    startCountdown()
                }
            } catch {
                await MainActor.run {
                    localErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }

            await MainActor.run {
                isSendingCode = false
            }
        }
    }

    private func verifyCodeTapped() {
        localErrorMessage = nil
        guard isPhoneValid, isCodeValid, !isVerifyingCode else { return }

        let fullPhone = e164Phone
        let code = smsCode.trimmingCharacters(in: .whitespacesAndNewlines)

        isVerifyingCode = true

        Task {
            do {
                try await authService.verifySMSCode(phoneNumber: fullPhone, code: code)
            } catch {
                await MainActor.run {
                    localErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }

            await MainActor.run {
                isVerifyingCode = false
            }
        }
    }

    private func startCountdown() {
        countdown = 60
        Task {
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                countdown -= 1
            }
        }
    }
}
