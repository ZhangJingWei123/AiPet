import SwiftUI
import StoreKit

/// AIPet Plus 订阅中心（Sheet）
/// - 展示权益、价格方案，并通过后端 Mock 接口完成本地演示级订阅
struct AIPetPlusView: View {
    enum SourceContext {
        case generic      // 设置页 / 性格升级入口
        case limitReached // 对话体力耗尽入口
    }

    enum Plan: String, CaseIterable, Identifiable {
        case monthly
        case yearly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .monthly: return "月度订阅"
            case .yearly: return "年度订阅"
            }
        }

        var priceText: String {
            switch self {
            case .monthly: return "￥19 / 月"
            case .yearly: return "￥168 / 年"
            }
        }

        /// 对应的 Mock 会员天数
        var durationDays: Int {
            switch self {
            case .monthly: return 30
            case .yearly: return 365
            }
        }
    }

    let source: SourceContext

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService

    @State private var selectedPlan: Plan = .monthly
    @State private var isProcessing: Bool = false
    @State private var localError: String?

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var selectedPlusPlan: AuthService.PlusPlan {
        switch selectedPlan {
        case .monthly:
            return .monthly
        case .yearly:
            return .yearly
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerView

                    benefitsView

                    planPickerView

                    statusView

                    subscribeButton

                    if let localError {
                        Text(localError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.top, 4)
                    }

                    Spacer(minLength: 12)
                }
                .padding(20)
            }
            .onAppear {
                AnalyticsService.shared.trackEvent(
                    "plus_view_appear",
                    props: [
                        "source": String(describing: source),
                        "default_plan": selectedPlan.rawValue
                    ]
                )
            }
            .navigationTitle("AIPet Plus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.yellow, Color.orange],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .shadow(color: .orange.opacity(0.35), radius: 10, x: 0, y: 6)

                    Image(systemName: "crown.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(source == .limitReached ? "体力已耗尽" : "解锁 AIPet Plus")
                        .font(.title3.weight(.semibold))

                    Text(source == .limitReached ? "今日普通对话次数已用完，开通 Plus 即可无限畅聊。" : "获得无限对话、高智商性格和更酷的家园体验。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    VStack(alignment: .leading, spacing: 4) {
                        Text("限时内测 · 虚构价格，仅用于演示")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text("当前版本所有扣费均为 Mock，不会产生真实支付。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 8)
        }
    }

    private var benefitsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("会员特权")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                benefitRow(systemImage: "infinity", title: "无限对话", subtitle: "取消每日 20 次上限，随时陪你聊天与倾诉。")

                benefitRow(systemImage: "brain.head.profile", title: "高智商毒舌助手", subtitle: "解锁「Snarky Genius」高级性格 DNA，获得理智、微讽刺、博学的陪伴风格。")

                benefitRow(systemImage: "house.lodge.fill", title: "专属家园皮肤", subtitle: "优先体验未来的金色主题家园与互动家具（规划中）。")
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func benefitRow(systemImage: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var planPickerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择订阅方案")
                .font(.headline)

            Picker("订阅方案", selection: $selectedPlan) {
                ForEach(Plan.allCases) { plan in
                    Text(plan.title).tag(plan)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text(selectedPlan.priceText)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if selectedPlan == .yearly {
                    Text("约合 ￥14 / 月")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if authService.isPlusActive, let expire = authService.plusExpiresAt {
                Text("当前已是 Plus 会员")
                    .font(.subheadline)
                Text("到期时间：" + Self.dateFormatter.string(from: expire))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if authService.isPlusMember {
                Text("会员信息异常")
                    .font(.subheadline)
                Text("检测到历史 Plus 标记，但有效期已过，请重新订阅。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("当前账号：普通用户")
                    .font(.subheadline)
                Text("登录后开通 Plus 将与当前账号绑定，仅用于本环境演示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private var subscribeButton: some View {
        Button(action: onSubscribeTapped) {
            HStack {
                if isProcessing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(authService.isPlusActive ? "续费 Plus" : "立即开通 Plus")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Color.orange, Color.pink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .orange.opacity(0.35), radius: 14, x: 0, y: 8)
        }
        .padding(.top, 8)
        .disabled(isProcessing)
    }

    private func onSubscribeTapped() {
        guard authService.isLoggedIn else {
            localError = "请先登录账号，再订阅 Plus。"
            return
        }

        localError = nil
        isProcessing = true

        AnalyticsService.shared.trackEvent(
            "plus_subscribe_tap",
            props: [
                "plan": selectedPlan.rawValue,
                "price_text": selectedPlan.priceText
            ]
        )

        Task {
            do {
                try await authService.purchasePlus(plan: selectedPlusPlan)
                await authService.refreshMembershipStatus()
                await MainActor.run {
                    isProcessing = false
                    dismiss()
                }

                AnalyticsService.shared.trackEvent(
                    "plus_purchase_success",
                    props: [
                        "plan": selectedPlan.rawValue,
                        "price_text": selectedPlan.priceText
                    ]
                )
            } catch {
                await MainActor.run {
                    isProcessing = false
                    let message = authService.lastPurchaseErrorMessage ?? error.localizedDescription
                    localError = "订阅失败：" + message
                }

                AnalyticsService.shared.trackEvent(
                    "plus_purchase_failed",
                    props: [
                        "plan": selectedPlan.rawValue,
                        "reason": authService.lastPurchaseErrorMessage ?? error.localizedDescription
                    ]
                )
            }
        }
    }
}
