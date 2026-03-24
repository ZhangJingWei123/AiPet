import SwiftUI
import SwiftData

/// 2.5D（等轴测）风格家园骨架
///
/// 这里不做真实资源接入，仅实现视觉结构：
/// - 等轴测地板
/// - 若干「家具方块」
/// - 宠物立在中央（带悬浮动画与情绪气泡）
struct PetHomeView: View {
    let pet: Pet
    @EnvironmentObject private var authService: AuthService

    @Environment(\.modelContext) private var context
    @State private var memorySnippets: [MemoryEntry] = []
    @State private var selectedPersonality: Pet.Personality

    init(pet: Pet) {
        self.pet = pet
        _selectedPersonality = State(initialValue: pet.personality)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack {
                Spacer(minLength: 8)

                IsometricStageView(pet: pet, isPlusActive: authService.isPlusActive)
                    .frame(height: proxy.size.height * 0.6)

                // 简单的「记忆碎片」展示区域
                if !memorySnippets.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("记忆碎片")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(memorySnippets.prefix(3), id: \.id) { entry in
                            Text("• \(entry.content)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

                // 多重人格选择器
                PersonalitySelectorView(personality: $selectedPersonality) { newValue in
                    updatePersonality(to: newValue)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                loadMemories()
            }
        }
    }

    private func loadMemories() {
        let petID = pet.id
        let descriptor = FetchDescriptor<MemoryEntry>(
            predicate: #Predicate { entry in
                entry.petID == petID
            },
            sortBy: [
                SortDescriptor(\.importance, order: .reverse),
                SortDescriptor(\.timestamp, order: .reverse)
            ]
        )

        do {
            let all = try context.fetch(descriptor)
            memorySnippets = Array(all.prefix(3))
        } catch {
            print("加载记忆碎片失败: \(error)")
        }
    }

    private func updatePersonality(to newValue: Pet.Personality) {
        // 本地状态先行更新，提升 UI 反馈速度
        if pet.personality == newValue { return }

        pet.personality = newValue

        // SwiftData 模型已被标记为脏数据，尝试保存；失败时仅打印错误，不打断 UI
        do {
            try context.save()
        } catch {
            print("更新人格失败: \(error)")
        }
    }
}

/// 人格选择器：segmented control + 颜色联动（通过 RootView 的 EmotionMeshBackground 使用 pet.themeColor）
private struct PersonalitySelectorView: View {
    @Binding var personality: Pet.Personality
    var onChange: (Pet.Personality) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("人格模式")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Picker("人格模式", selection: Binding(
                get: { personality },
                set: { newValue in
                    personality = newValue
                    onChange(newValue)
                }
            )) {
                Text("温柔治愈").tag(Pet.Personality.gentle)
                Text("毒舌损友").tag(Pet.Personality.sarcastic)
                Text("高冷克制").tag(Pet.Personality.cool)
            }
            .pickerStyle(.segmented)
        }
    }
}

// 根据宠物物种自动切换主题色
private extension Pet {
    var themeColor: Color {
        // 先根据物种给一个基础色，再用人格做整体调制
        let base: Color
        switch species.lowercased() {
        case "cat", "kitty", "猫":
            base = .orange
        case "dog", "puppy", "狗":
            base = .blue
        case "rabbit", "bunny", "兔":
            base = .purple
        default:
            base = .accentColor
        }

        switch personality {
        case .gentle:
            // 温柔：偏粉橙调
            return Color(red: 1.0, green: 0.68, blue: 0.55)
        case .sarcastic:
            // 毒舌：深紫偏冷
            return Color.purple
        case .cool:
            // 高冷：偏冷灰
            return Color.gray.opacity(0.85)
        }
    }
}

/// 家具配置（位于 3x3 网格中的行列）
private struct FurnitureConfig: Identifiable, Equatable {
    let id = UUID()
    let row: Int
    let col: Int
    let name: String
    let key: String
    let color: Color
}

/// 2.5D 等轴测舞台：3x3 地砖 + 家具交互 + 宠物悬浮
private struct IsometricStageView: View {
    let pet: Pet
    let isPlusActive: Bool
    private let themeColor: Color

    @State private var selectedFurniture: FurnitureConfig?
    @State private var interactionText: String = ""

    init(pet: Pet, isPlusActive: Bool) {
        self.pet = pet
        self.isPlusActive = isPlusActive
        self.themeColor = pet.themeColor
    }

    private var furnitureConfigs: [FurnitureConfig] {
        [
            FurnitureConfig(row: 0, col: 1, name: "舒适沙发", key: "sofa", color: themeColor.opacity(0.9)),
            FurnitureConfig(row: 1, col: 2, name: "小鱼缸", key: "fishbowl", color: Color.cyan.opacity(0.9)),
            FurnitureConfig(row: 2, col: 0, name: "阅读角", key: "reading", color: Color.green.opacity(0.85))
        ]
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let tileWidth = size.width * 0.3
            let tileHeight = tileWidth * 0.55

            ZStack {
                // 3x3 等轴测地砖网格
                ForEach(0..<3, id: \.self) { row in
                    ForEach(0..<3, id: \.self) { col in
                        let offset = tileOffset(row: row, col: col, tileWidth: tileWidth, tileHeight: tileHeight)

                        IsometricTileView(
                            baseColor: themeColor,
                            highlight: Color.white,
                            intensity: tileIntensity(row: row, col: col)
                        )
                        .frame(width: tileWidth, height: tileHeight * 2.0)
                        .offset(x: offset.width, y: offset.height + 24)
                    }
                }

                // 家具方块（可点击）
                ForEach(furnitureConfigs) { furniture in
                    let offset = tileOffset(row: furniture.row, col: furniture.col, tileWidth: tileWidth, tileHeight: tileHeight)

                    IsometricFurniture(color: furniture.color)
                        .frame(width: tileWidth * 0.9, height: tileHeight * 2.0)
                        .offset(x: offset.width, y: offset.height - tileHeight * 0.1)
                        .onTapGesture {
                            selectedFurniture = furniture
                            interactionText = ""
                        }
                        .accessibilityLabel(Text(furniture.name))
                }

                // 宠物角色（悬浮头像 + 情绪气泡）
                PetAvatarView(pet: pet, isPlusActive: isPlusActive)
                    .offset(y: -tileHeight * 0.4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 32)
        .sheet(item: $selectedFurniture) { furniture in
            FurnitureSheetView(
                furniture: furniture,
                petName: pet.name,
                interactionText: $interactionText
            )
        }
    }

    /// 等轴测网格坐标到屏幕偏移的转换
    private func tileOffset(row: Int, col: Int, tileWidth: CGFloat, tileHeight: CGFloat) -> CGSize {
        // 以 (1,1) 为中心
        let dx = CGFloat(col - row) * tileWidth * 0.5
        let dy = CGFloat(row + col - 2) * tileHeight * 0.5
        return CGSize(width: dx, height: dy)
    }

    /// 中心砖更亮，周边略暗，增强层次感
    private func tileIntensity(row: Int, col: Int) -> Double {
        let centerDistance = abs(row - 1) + abs(col - 1)
        switch centerDistance {
        case 0: return 1.0
        case 1: return 0.9
        default: return 0.8
        }
    }
}

/// 单块等轴测地砖（带描边与渐变）
private struct IsometricTileView: View {
    let baseColor: Color
    let highlight: Color
    let intensity: Double

    var body: some View {
        IsometricTile()
            .fill(
                LinearGradient(
                    colors: [
                        baseColor.opacity(0.25 * intensity),
                        baseColor.opacity(0.05 * intensity)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                IsometricTile()
                    .stroke(highlight.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 10)
    }
}

/// 家具弹出 Sheet：展示名称与一条 mock 互动描述
private struct FurnitureSheetView: View {
    let furniture: FurnitureConfig
    let petName: String
    @Binding var interactionText: String

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 40, height: 4)
                .padding(.top, 8)

            Text(furniture.name)
                .font(.title2.weight(.semibold))

            Button {
                interactionText = mockInteraction()
            } label: {
                Text("宠物互动")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }

            if !interactionText.isEmpty {
                Text(interactionText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            Spacer(minLength: 12)
        }
        .padding()
    }

    private func mockInteraction() -> String {
        switch furniture.key {
        case "sofa":
            return "\(petName) 跳上了沙发，开始舒服地揉爪子。"
        case "fishbowl":
            return "\(petName) 靠近小鱼缸，好奇地盯着小鱼，尾巴轻轻摇晃。"
        case "reading":
            return "\(petName) 蜷缩在阅读角的软垫上，安静地陪你看书。"
        default:
            return "\(petName) 在 \(furniture.name) 附近转了几圈，露出满足的表情。"
        }
    }
}

/// 等轴测菱形地板基础形状
private struct IsometricTile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let cx = rect.midX
        let cy = rect.midY

        let top = CGPoint(x: cx, y: cy - height * 0.3)
        let right = CGPoint(x: cx + width * 0.35, y: cy)
        let bottom = CGPoint(x: cx, y: cy + height * 0.3)
        let left = CGPoint(x: cx - width * 0.35, y: cy)

        path.move(to: top)
        path.addLine(to: right)
        path.addLine(to: bottom)
        path.addLine(to: left)
        path.addLine(to: top)

        return path
    }
}

/// 简化的等轴测家具块（立体小方块）
private struct IsometricFurniture: View {
    var color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 6)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
        }
        .rotation3DEffect(.degrees(60), axis: (x: 1, y: 0, z: 0))
        .rotation3DEffect(.degrees(-45), axis: (x: 0, y: 1, z: 0))
    }
}

/// 基于 MeshGradient 的情绪驱动背景：颜色与动效由宠物能量 / 社交度调制
struct EmotionMeshBackground: View {
    let pet: Pet

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                TimelineView(.animation) { context in
                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: animatedPoints(phase: sin(context.date.timeIntervalSinceReferenceDate / 4.0)),
                        colors: meshColors
                    )
                    .hueRotation(.degrees(hueOffset))
                    .opacity(0.9)
                    .blur(radius: 42)
                    .ignoresSafeArea()
                }
            } else {
                TimelineView(.animation) { context in
                    LinearGradient(
                        colors: palette,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .hueRotation(.degrees(hueOffset + sin(context.date.timeIntervalSinceReferenceDate / 4.0) * 4.0))
                    .opacity(0.9)
                    .blur(radius: 42)
                    .ignoresSafeArea()
                }
            }
        }
    }

    /// 按情绪切换不同的配色方案
    private var palette: [Color] {
        let theme = pet.themeColor
        let energy = Double(pet.energy)
        let sociability = Double(pet.sociability)

        if energy > 70 && sociability > 60 {
            // 兴奋 / 外向：更鲜艳的暖色 + 一点蓝紫对比
            return [
                theme,
                .orange.opacity(0.9),
                .pink.opacity(0.85),
                .yellow.opacity(0.85),
                .blue.opacity(0.6)
            ]
        } else if energy < 30 {
            // 困倦：偏冷、柔和的蓝紫系
            return [
                theme.opacity(0.4),
                .blue.opacity(0.8),
                .indigo.opacity(0.8),
                .purple.opacity(0.7),
                .mint.opacity(0.6)
            ]
        } else if sociability < 40 {
            // 略孤僻：加入一些偏灰的青绿，营造安静氛围
            return [
                theme.opacity(0.6),
                .teal.opacity(0.7),
                .blue.opacity(0.65),
                .gray.opacity(0.4),
                .purple.opacity(0.6)
            ]
        } else {
            // 默认：主题色 + 青绿过渡
            return [
                theme,
                theme.opacity(0.7),
                .teal.opacity(0.8),
                .cyan.opacity(0.8),
                .purple.opacity(0.6)
            ]
        }
    }

    private var meshColors: [Color] {
        let c = palette
        guard c.count >= 5 else { return Array(repeating: .gray, count: 9) }
        return [
            c[0], c[1], c[2],
            c[1], c[2], c[3],
            c[2], c[3], c[4]
        ]
    }

    private func animatedPoints(phase: Double) -> [SIMD2<Float>] {
        let d = Float(0.04 * phase)
        return [
            SIMD2(0.00 + d, 0.00), SIMD2(0.50, 0.00 + d), SIMD2(1.00 - d, 0.00),
            SIMD2(0.00, 0.50 - d), SIMD2(0.50 + d, 0.50), SIMD2(1.00, 0.50 + d),
            SIMD2(0.00 + d, 1.00), SIMD2(0.50, 1.00 - d), SIMD2(1.00 - d, 1.00)
        ]
    }

    /// 能量越高越偏暖，越低越偏冷
    private var hueOffset: Double {
        let normalized = (Double(pet.energy) - 50.0) / 50.0 // [-1, 1]
        return normalized * 10.0
    }
}

/// 宠物头像：TimelineView + Canvas 实现悬浮呼吸与动态阴影
private struct PetAvatarView: View {
    let pet: Pet
    let isPlusActive: Bool

    @State private var tapScale: CGFloat = 1.0
    @State private var tapRingOpacity: Double = 0.0

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let phase = (time.truncatingRemainder(dividingBy: 2.0)) / 2.0
            let wave = sin(phase * .pi * 2)
            let yOffset = CGFloat(wave) * -6.0          // 上下轻微漂浮（振幅约 6pt）
            let shadowScale = 0.9 - 0.15 * CGFloat(wave) // 飘起时阴影变小，落下时变大

            ZStack {
                // 地面动态阴影（Canvas）
                Canvas { canvasContext, size in
                    let shadowWidth = size.width * shadowScale
                    let shadowHeight = size.height * 0.25 * shadowScale
                    let rect = CGRect(
                        x: (size.width - shadowWidth) / 2,
                        y: size.height * 0.65,
                        width: shadowWidth,
                        height: shadowHeight
                    )
                    let path = Path(ellipseIn: rect)
                    canvasContext.fill(path, with: .color(.black.opacity(0.18)))
                }
                .frame(width: 120, height: 60)

                VStack(spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        Circle()
                            .fill(pet.themeColor)
                            .frame(width: 72, height: 72)
                            .overlay(
                                Text(String(pet.name.prefix(1)))
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.white)
                            )

                        if isPlusActive {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.yellow)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Circle())
                                .offset(x: 6, y: -6)
                        }

                        if let emoji = emotionEmoji(time: time) {
                            Text(emoji)
                                .font(.title2)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .offset(x: 6, y: -6)
                        }
                    }

                    Text(pet.name)
                        .font(.headline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .offset(y: -24)
            }
            // 整体上下漂浮
            .offset(y: yOffset)
            .scaleEffect(tapScale)
            .overlay(
                Circle()
                    .stroke(pet.themeColor.opacity(tapRingOpacity), lineWidth: 3)
                    .scaleEffect(tapScale * 1.25)
                    .opacity(tapRingOpacity)
            )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            performTapFeedback()
        }
    }

    /// 根据能量与社交度决定情绪气泡
    private func emotionEmoji(time: TimeInterval) -> String? {
        if pet.energy < 30 {
            return "😴"
        } else if pet.energy > 70 {
            return "✨"
        } else if pet.sociability > 70 {
            // 使用时间片段让 💬 间歇出现，增加“随机感”
            let phase = Int(time) % 4
            return phase < 2 ? "💬" : nil
        } else {
            return nil
        }
    }

    /// 轻微缩放 + 外圈波纹，强调点击反馈
    private func performTapFeedback() {
        withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.65)) {
            tapScale = 1.06
            tapRingOpacity = 0.9
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                tapScale = 1.0
                tapRingOpacity = 0.0
            }
        }
    }
}
