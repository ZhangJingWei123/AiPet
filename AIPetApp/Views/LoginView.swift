import SwiftUI
import AuthenticationServices

/// 登录页：支持手机号验证码登录与 Apple ID 登录
struct LoginView: View {
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var countryCode: String = "+86"
    @State private var phoneNumber: String = ""
    @State private var smsCode: String = ""

    @State private var isSendingCode: Bool = false
    @State private var countdown: Int = 0
    @State private var isVerifyingCode: Bool = false

    @State private var localErrorMessage: String?

    private var isPhoneValid: Bool {
        !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isCodeValid: Bool {
        smsCode.trimmingCharacters(in: .whitespacesAndNewlines).count == 6
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.blue.opacity(0.25), Color.purple.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 40)

                VStack(spacing: 8) {
                    Image(systemName: "pawprint.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white, Color.accentColor)

                    Text("欢迎回来")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)

                    Text("登录后即可和你的 AIPet 随时聊天，解锁专属记忆与更多会员功能。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 20) {
                    phoneLoginSection

                    if let message = localErrorMessage ?? authService.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()
                        .overlay(
                            HStack {
                                Spacer()
                                Text("或")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        )

                    SignInWithAppleButtonView()
                        .frame(height: 50)
                }
                .padding(20)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 24)

                Spacer()
            }
        }
        .onChange(of: authService.isLoggedIn) { loggedIn in
            if loggedIn {
                dismiss()
            }
        }
    }

    // MARK: - 手机号登录区域

    private var phoneLoginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("手机号登录")
                .font(.headline)

            HStack(spacing: 8) {
                Menu {
                    Button("中国 +86") { countryCode = "+86" }
                    Button("美国 +1") { countryCode = "+1" }
                    Button("日本 +81") { countryCode = "+81" }
                } label: {
                    HStack {
                        Text(countryCode)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                TextField("请输入手机号", text: $phoneNumber)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 8) {
                TextField("6 位验证码", text: $smsCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

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
                .controlSize(.medium)
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
            .frame(maxWidth: .infinity)
            .disabled(!isPhoneValid || !isCodeValid || isVerifyingCode || authService.isLoading)
        }
    }

    // MARK: - 动作

    private func sendCodeTapped() {
        localErrorMessage = nil
        guard isPhoneValid, countdown == 0, !isSendingCode else { return }

        let fullPhone = countryCode + phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
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

        let fullPhone = countryCode + phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = smsCode.trimmingCharacters(in: .whitespacesAndNewlines)

        isVerifyingCode = true

        Task {
            do {
                try await authService.verifySMSCode(phoneNumber: fullPhone, code: code)
                // 登录成功后，RootView 会根据 isLoggedIn 自动关闭登录页
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

// MARK: - Apple 登录按钮封装

struct SignInWithAppleButtonView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var authService: AuthService

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                handleAuthorization(authorization)
            case .failure(let error):
                print("Apple 登录失败: \(error)")
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .cornerRadius(12)
    }

    private func handleAuthorization(_ authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            return
        }

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
}

