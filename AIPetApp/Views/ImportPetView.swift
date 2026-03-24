import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// 真实宠物导入向导
struct ImportPetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var authService: AuthService

    // Step 1 - 照片
    @State private var selectedItem: PhotosPickerItem?
    @State private var originalImage: UIImage?
    @State private var stylizedImage: UIImage?
    @State private var isStylizing = false

    private let styleService: ImageStyleTransferService = LocalFilterStyleTransferService()

    // Step 2 - 问卷与 DNA
    @State private var selectedAnswers: [String: String] = [:]
    @State private var generatedEnergy: Int = 50
    @State private var generatedSociability: Int = 50
    @State private var generatedIndependence: Int = 50
    @State private var generatedCuriosity: Int = 50
    @State private var generatedTenderness: Int = 50
    private let dnaBuilder: PhotoDNABuilder = DummyPhotoDNABuilder()

    /// 是否启用高级性格 DNA：「高智商毒舌助手」
    @State private var isSnarkyGeniusSelected: Bool = false

    // Step 3 - 名字和物种
    @State private var petName: String = ""
    @State private var species: String = "Cat"

    // Step & 完成状态
    @State private var stepIndex: Int = 0
    @State private var isCreating = false

    @State private var showPlusSheet: Bool = false
    @State private var showLoginAlert: Bool = false

    private var canGoNext: Bool {
        switch stepIndex {
        case 0:
            return stylizedImage != nil
        case 1:
            return true
        case 2:
            return !petName.trimmingCharacters(in: .whitespaces).isEmpty
        default:
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $stepIndex) {
                stepPhotoView
                    .tag(0)
                stepQuestionnaireView
                    .tag(1)
                stepNameSpeciesView
                    .tag(2)
                stepFinishView
                    .tag(3)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Divider()

            HStack {
                Button("上一步") {
                    withAnimation { stepIndex = max(stepIndex - 1, 0) }
                }
                .disabled(stepIndex == 0 || isCreating)

                Spacer()

                if stepIndex < 3 {
                    Button("下一步") {
                        if stepIndex == 1 {
                            Task { await generateDNA() }
                        }
                        withAnimation { stepIndex = min(stepIndex + 1, 3) }
                    }
                    .disabled(!canGoNext || isCreating)
                } else {
                    Button {
                        Task { await createPetAndClose() }
                    } label: {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("完成创建")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreating)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showPlusSheet) {
            AIPetPlusView(source: .generic)
                .environmentObject(authService)
        }
        .alert("请先登录", isPresented: $showLoginAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("登录后才能解锁高级性格 DNA 与 Plus 会员。")
        }
    }

    // MARK: - Step 1: 上传照片

    private var stepPhotoView: some View {
        VStack(spacing: 16) {
            Text("Step 1 · 上传宠物照片")
                .font(.title3.bold())

            Text("选择一张你宠物的照片，我们会将其风格化为可爱的卡通形象（当前为本地滤镜模拟）。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
                Label("从相册选择照片", systemImage: "photo.on.rectangle")
                    .font(.body.bold())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Capsule())
            }
            .onChange(of: selectedItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadAndStylize(item: newItem) }
            }

            if let output = stylizedImage {
                Image(uiImage: output)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(Color.white, lineWidth: 4)
                    )
                    .shadow(radius: 10)
                    .padding(.top, 8)
            } else if isStylizing {
                ProgressView("正在生成卡通形象…")
                    .padding()
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 180, height: 180)
                    .overlay(
                        Image(systemName: "pawprint")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    )
            }

            Spacer()
        }
        .padding()
    }

    private func loadAndStylize(item: PhotosPickerItem) async {
        isStylizing = true
        defer { isStylizing = false }

        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                self.originalImage = uiImage
                self.stylizedImage = try await styleService.stylize(image: uiImage)
            }
        } catch {
            // 简单降级：直接使用原图
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                self.originalImage = uiImage
                self.stylizedImage = uiImage
            }
        }
    }

    // MARK: - Step 2: 性格问卷

    private let questions: [(id: String, title: String, options: [String])] = [
        ("q1", "你的宠物平时更喜欢？", ["独自玩耍", "黏着主人"]),
        ("q2", "当有陌生人来访时，它通常？", ["躲起来观察", "主动上前打招呼"]),
        ("q3", "面对新玩具或新环境，它会？", ["谨慎慢慢探索", "立刻冲上去研究"]),
        ("q4", "当你在忙碌时，它更常？", ["自己找乐子", "一直在你身边等待"]),
        ("q5", "它的睡觉姿势给你的感觉？", ["蜷成一团很有安全感", "四仰八叉完全放松"])
    ]

    private var stepQuestionnaireView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Step 2 · 性格小问卷")
                    .font(.title3.bold())

                Text("简单回答几道题，让 AIPet 更像真实的它。答案会用于生成性格 DNA。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                ForEach(questions, id: \.id) { q in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(q.title)
                            .font(.headline)

                        HStack(spacing: 12) {
                            ForEach(q.options, id: \.self) { option in
                                let isSelected = selectedAnswers[q.id] == option
                                Button {
                                    selectedAnswers[q.id] = option
                                } label: {
                                    VStack(spacing: 4) {
                                        Text(option)
                                            .font(.subheadline)
                                            .multilineTextAlignment(.center)
                                            .padding(8)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(6)
                                    .background(isSelected ? Color.accentColor.opacity(0.2) : Color(.systemBackground))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                // 实时预览雷达图
                VStack(spacing: 12) {
                    Text("性格 DNA 预览")
                        .font(.headline)
                    PersonalityRadarView(
                        energy: generatedEnergy,
                        sociability: generatedSociability,
                        independence: generatedIndependence,
                        curiosity: generatedCuriosity,
                        tenderness: generatedTenderness
                    )
                    .frame(height: 220)
                }
                .padding(.top, 8)

                // 高级性格 DNA 选择
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("高级性格 DNA")
                            .font(.headline)
                        Text("AIPet Plus")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.2), in: Capsule())
                    }

                    Button {
                        handleSnarkyGeniusTap()
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("高智商毒舌助手")
                                        .font(.subheadline.weight(.semibold))
                                    Label("Plus", systemImage: "crown.fill")
                                        .labelStyle(.titleAndIcon)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            LinearGradient(
                                                colors: [Color.yellow.opacity(0.9), Color.orange.opacity(0.9)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .foregroundStyle(.white)
                                        .clipShape(Capsule())
                                }

                                Text("回复风格更加理智、博学，带一点安全范围内的毒舌与吐槽。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: isSnarkyGeniusSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(isSnarkyGeniusSelected ? Color.accentColor : Color.secondary)
                        }
                        .padding(12)
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(isSnarkyGeniusSelected ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)

                Spacer(minLength: 20)
            }
            .padding()
        }
    }

    private func generateDNA() async {
        let payload = PhotoDNABuilderPayload(
            photoData: originalImage?.jpegData(compressionQuality: 0.7),
            questionnaireAnswers: selectedAnswers,
            behaviorSignals: [:]
        )

        do {
            let dna = try await dnaBuilder.buildDNA(from: payload)
            await MainActor.run {
                withAnimation {
                    generatedEnergy = dna.energy
                    generatedSociability = dna.sociability
                    generatedIndependence = dna.independence
                    generatedCuriosity = dna.curiosity
                    generatedTenderness = dna.tenderness
                }
            }
        } catch {
            // 保持默认中性 DNA
        }
    }

    /// 处理「高智商毒舌助手」选项点击
    private func handleSnarkyGeniusTap() {
        // 未登录：引导用户先登录
        guard authService.isLoggedIn else {
            showLoginAlert = true
            return
        }

        // 已登录但非 Plus：直接弹出订阅页，不修改选择状态
        guard authService.isPlusActive else {
            showPlusSheet = true
            return
        }

        // Plus 会员：切换选择状态
        isSnarkyGeniusSelected.toggle()
    }

    // MARK: - Step 3: 名字 & 物种

    private let speciesOptions = ["Cat", "Dog", "Rabbit", "Other"]

    private var stepNameSpeciesView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Step 3 · 给它一个身份")
                    .font(.title3.bold())

                Text("起一个喜欢的名字，并选择物种。下方会展示最终的性格雷达图总结。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 12) {
                    Text("名字")
                        .font(.headline)
                    TextField("例如：Mochi", text: $petName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("物种")
                        .font(.headline)
                    Picker("物种", selection: $species) {
                        ForEach(speciesOptions, id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(spacing: 12) {
                    Text("性格雷达图总结")
                        .font(.headline)
                    PersonalityRadarView(
                        energy: generatedEnergy,
                        sociability: generatedSociability,
                        independence: generatedIndependence,
                        curiosity: generatedCuriosity,
                        tenderness: generatedTenderness
                    )
                    .frame(height: 220)
                }

                Spacer(minLength: 20)
            }
            .padding()
        }
    }

    // MARK: - Step 4: 完成动画

    @State private var appearScale: CGFloat = 0.2
    @State private var appearOpacity: Double = 0.0

    private var stepFinishView: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 220, height: 220)

                if let image = stylizedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 180, height: 180)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "pawprint.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .scaleEffect(appearScale)
            .opacity(appearOpacity)
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                    appearScale = 1.0
                    appearOpacity = 1.0
                }
            }

            Text("新宠物诞生！")
                .font(.title2.bold())

            Text("我们已经根据你的照片和问卷，为它生成了专属的性格 DNA。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            PersonalityRadarView(
                energy: generatedEnergy,
                sociability: generatedSociability,
                independence: generatedIndependence,
                curiosity: generatedCuriosity,
                tenderness: generatedTenderness
            )
            .frame(height: 220)

            Spacer()
        }
        .padding()
    }

    // MARK: - 创建并关闭

    /// 创建 SwiftData 对象并关闭导入页
    private func createPetAndClose() async {
        guard !petName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        await MainActor.run { isCreating = true }

        await MainActor.run {
            let dna = PersonalityDNA(
                energy: generatedEnergy,
                sociability: generatedSociability,
                independence: generatedIndependence,
                curiosity: generatedCuriosity,
                tenderness: generatedTenderness,
                isSnarkyGenius: isSnarkyGeniusSelected
            )
            let pet = Pet(
                name: petName,
                species: species,
                energy: dna.energy,
                sociability: dna.sociability,
                independence: dna.independence
            )
            pet.personalityDNA = dna

            context.insert(dna)
            context.insert(pet)

            NotificationCenter.default.post(
                name: .didCreatePet,
                object: nil,
                userInfo: ["petID": pet.id]
            )
        }

        await MainActor.run {
            isCreating = false
            dismiss()
        }
    }
}

extension Notification.Name {
    static let didCreatePet = Notification.Name("ImportPetView.didCreatePet")
}
