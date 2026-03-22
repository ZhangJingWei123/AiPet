# AIPetApp: 全栈 AI 电子宠物项目 (v1.0-Ultimate)

本仓库是一个结合了 **SwiftUI (iOS)** 与 **Go (Hertz)** 的全栈 AI 电子宠物项目。它不仅仅是一个聊天机器人，而是一个具备环境感知、长期记忆、全双工语音以及多模态视觉能力的“智能生命体”。

## 🚀 核心架构

- **iOS 客户端 (AIPetApp)**: 采用 SwiftUI 构建，集成 SwiftData 本地存储、StoreKit 2 支付、WeatherKit 天气感知、EventKit 日程管理。
- **Go 服务端 (AIPetServer)**: 采用 Hertz 框架，PostgreSQL 数据库，集成 JWT 认证、腾讯云短信、APNs 推送、Apple ID 登录校验。

## 🧠 核心超能力 (AI Features)

### 1. 长期记忆与 RAG (Long-term Memory)
- **实现**: `MemoryService.swift` (iOS) + `models/ChatMessage` (Go)。
- **逻辑**: 宠物会自动提取对话中的关键事实（用户偏好、重要日期、共同回忆），通过向量检索（预留）或结构化存储实现长期记忆，对话时会自动注入提示词。

### 2. 多模态视觉感知 (Vision Capability)
- **实现**: `LLMService.swift`。
- **逻辑**: 支持发送照片给宠物。宠物能通过 GPT-4o-vision 等模型“看懂”照片内容，并结合当前情感状态进行反馈。

### 3. 全双工语音通话 (Full-Duplex Voice)
- **实现**: `VoiceInteractionService.swift`。
- **逻辑**: 基于 `AVAudioEngine` 和实时音频流，支持打断（Interruption）和并发处理，模拟真实的电话沟通体验。

### 4. 环境与日程感知 (Context Awareness)
- **天气感知**: 通过 `WeatherService.swift` 获取实时天气，注入宠物提示词（如：下雨天宠物会提醒你带伞，性格会变忧郁）。
- **日程打理**: 通过 `CalendarService.swift` 读取系统日程，宠物会自动提醒你即将到来的会议或活动。

### 5. 多重人格切换 (Personality System)
- **实现**: `SystemPromptBuilder.swift`。
- **逻辑**: 内置“毒舌天才”、“治愈萌宠”等多种人格，动态生成 System Prompt。

## 💰 商业化模块

### 1. AIPet Plus 会员体系
- **实现**: `AuthService.swift` + `handlers/membership.go`。
- **支付**: 集成 StoreKit 2，支持月度/年度订阅。
- **权益**: 无限次视觉分析、专属人格、高优先级回复、云端备份。

### 2. 多样化登录
- **Apple ID 登录**: 完整的 OAuth 流程。
- **手机验证码**: 集成腾讯云短信服务。

## 🛠️ 本地开发指引 (Trae/Xcode)

### iOS 端配置
1. 用 Xcode 打开 `AIPetApp.xcodeproj`。
2. 在 `AuthService.swift` 中修改 `apiBaseURL` 为你的后端地址。
3. 在 `LLMService.swift` 中配置你的 AI 厂商 API Key。
4. **必选能力**: 在 Signing & Capabilities 中开启 WeatherKit, App Groups, Push Notifications, In-App Purchase。

### 服务端配置
1. 进入 `AIPetServer/` 目录。
2. 配置环境变量（见下方）。
3. 运行: `go run main.go`。

### 关键环境变量
- `DATABASE_URL`: PostgreSQL 数据库地址。
- `JWT_SECRET`: JWT 签名密钥。
- `TENCENT_SMS_SECRET_ID/KEY`: 腾讯云 API 密钥。
- `APNS_AUTH_KEY`: APNs 推送证书 (.p8)。

## 📝 开发者备注 (致 Trae)
- 本项目采用 **MVVM** 架构。
- 网络层在 `Services/` 中进行了高度抽象。
- 如需增强宠物大脑，请优先修改 `SystemPromptBuilder.swift`。
- 如需调整数据模型，请同时修改 iOS 的 `Models/` 和 Go 的 `models/` 并运行自动迁移。

---
*Created by Aime Cloud Assistant*
