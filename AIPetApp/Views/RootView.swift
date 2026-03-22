import SwiftUI
import SwiftData

/// 应用根视图：承载多宠管理 + 家园 + Chat
struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Pet.createdAt) private var pets: [Pet]

    @EnvironmentObject private var authService: AuthService

    @State private var selectedPetID: UUID?
    @State private var isPresentingImport = false
    @State private var isPresentingSettings = false
    @State private var isPresentingLogin = false

    var body: some View {
        NavigationStack {
            Group {
                if let currentPet = currentPet {
                    VStack(spacing: 0) {
                        PetSwitcherView(pets: pets, selectedPetID: $selectedPetID)
                            .padding(.horizontal)
                            .padding(.top, 8)

                        Divider()

                        PetHomeView(pet: currentPet)

                        Divider()

                        ChatInterfaceView(pet: currentPet)
                            .safeAreaInset(edge: .bottom) {
                                Color.clear.frame(height: 0)
                            }
                    }
                } else {
                    EmptyStateView()
                }
            }
            .background(
                Group {
                    if let currentPet = currentPet {
                        EmotionMeshBackground(pet: currentPet)
                    } else {
                        Color(.systemBackground)
                    }
                }
            )
            .navigationTitle("AIPet Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isPresentingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }

                    Button {
                        isPresentingImport = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .onAppear {
                ensureSeedPetIfNeeded()
                isPresentingLogin = !authService.isLoggedIn
            }
            .sheet(isPresented: $isPresentingImport) {
                ImportPetView()
            }
            .sheet(isPresented: $isPresentingSettings) {
                SettingsView()
            }
            .fullScreenCover(isPresented: $isPresentingLogin) {
                LoginView()
                    .environmentObject(authService)
            }
            .onChange(of: authService.isLoggedIn) { loggedIn in
                isPresentingLogin = !loggedIn
            }
            .onReceive(NotificationCenter.default.publisher(for: .didCreatePet)) { notification in
                if let id = notification.userInfo?["petID"] as? UUID {
                    selectedPetID = id
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pushNotificationTapped)) { notification in
                // 简单示例：若 payload 中包含 petID，则跳转到对应宠物
                if let idString = notification.userInfo?["petID"] as? String,
                   let id = UUID(uuidString: idString) {
                    selectedPetID = id
                }
            }
        }
    }

    private var currentPet: Pet? {
        if let id = selectedPetID {
            return pets.first(where: { $0.id == id })
        }
        return pets.first
    }

    /// 首次启动时创建一个示例宠物，方便直接看到效果
    private func ensureSeedPetIfNeeded() {
        guard pets.isEmpty else { return }

        let home = Home(name: "默认家园")
        let dna = PersonalityDNA(energy: 80, sociability: 75, independence: 40, curiosity: 70, tenderness: 85)
        let pet = Pet(name: "Mochi", species: "Cat", energy: 80, sociability: 75, independence: 40)
        pet.personalityDNA = dna
        pet.home = home

        context.insert(home)
        context.insert(dna)
        context.insert(pet)

        selectedPetID = pet.id
    }
}

/// 多宠切换条
struct PetSwitcherView: View {
    let pets: [Pet]
    @Binding var selectedPetID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(pets, id: \._persistentModelID) { pet in
                    Button {
                        selectedPetID = pet.id
                    } label: {
                        VStack(spacing: 4) {
                            Text(pet.name)
                                .font(.headline)
                            Text(pet.species)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedPetID == pet.id ? Color.accentColor.opacity(0.15) : Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(selectedPetID == pet.id ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

/// 初始空状态
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pawprint.circle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("还没有宠物")
                .font(.title3)
            Text("可以在后续集成真实宠物导入流程后，从照片或问卷中创建你的第一只 AIPet。")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
