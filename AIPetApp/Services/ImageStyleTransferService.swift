import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 图片风格迁移服务协议：将真实照片转为卡通/Q 版风格
protocol ImageStyleTransferService {
    func stylize(image: UIImage) async throws -> UIImage
}

/// 本地滤镜实现：使用 CoreImage 组合漫画/色调分离等效果进行模拟
final class LocalFilterStyleTransferService: ImageStyleTransferService {
    private let context = CIContext()

    func stylize(image: UIImage) async throws -> UIImage {
        guard let inputCI = CIImage(image: image) else { return image }

        // 1. 边缘检测，强调轮廓
        let edgesFilter = CIFilter.edges()
        edgesFilter.inputImage = inputCI
        edgesFilter.intensity = 1.0

        guard let edgesImage = edgesFilter.outputImage else { return image }

        // 2. 色调分离，降低颜色层级，形成卡通块面
        let posterizeFilter = CIFilter.colorPosterize()
        posterizeFilter.inputImage = inputCI
        posterizeFilter.levels = 6

        guard let posterizedImage = posterizeFilter.outputImage else { return image }

        // 3. 调整饱和度和对比度，让颜色更鲜艳
        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = posterizedImage
        colorControls.saturation = 1.4
        colorControls.contrast = 1.1

        guard let colorAdjusted = colorControls.outputImage else { return image }

        // 4. 将边缘叠加到色块图上
        let composite = CIFilter.sourceAtopCompositing()
        composite.inputImage = edgesImage
        composite.backgroundImage = colorAdjusted

        guard let output = composite.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return image
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// 远程风格迁移服务协议占位，后续可接入火山引擎 / Stable Diffusion 等
protocol RemoteStyleTransferService: ImageStyleTransferService {
    /// 远程服务的基础 URL 或标识
    var endpointDescription: String { get }
}

