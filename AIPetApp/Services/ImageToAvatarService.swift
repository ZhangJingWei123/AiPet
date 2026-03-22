import Foundation
import SwiftUI

/// 占位：真实宠物照片 -> 虚拟头像生成服务
///
/// 说明：
/// - 后续可以接入内部/第三方的图片生成、风格化或 3D Avatar 服务；
/// - 这里仅定义协议与基本数据结构，方便后续替换具体实现。
protocol ImageToAvatarService {
    /// 输入：原始宠物照片
    /// 输出：用于前端展示的头像资源（当前简化为 SwiftUI Image/URL 占位）
    func generateAvatar(from originalPhotoData: Data) async throws -> PetAvatar
}

/// 用于代表生成后的头像资源
struct PetAvatar: Identifiable, Equatable {
    let id: UUID
    /// 远端资源地址（静态图 / 动图 / 3D 贴图等）
    let imageURL: URL?

    init(id: UUID = UUID(), imageURL: URL?) {
        self.id = id
        self.imageURL = imageURL
    }
}

/// 默认空实现，方便在 UI 中注入而不真正调用后端
struct DummyImageToAvatarService: ImageToAvatarService {
    func generateAvatar(from originalPhotoData: Data) async throws -> PetAvatar {
        // 真实实现中，可以将图片上传到服务端并返回生成后的资源地址
        return PetAvatar(imageURL: nil)
    }
}

