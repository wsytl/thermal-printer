//
//  PrintEngine+Image.swift
//  B3 热敏打印机 —— 图片加载 / 裁剪 / 旋转镜像
//
//  说明：EXIF 方向用 ImageIO 缩略图应用；旋转/翻转用 CGContext 变换
//

import AppKit
import CoreImage
import CoreText
import ImageIO

extension PrintEngine {

    // MARK: - 图片加载 / 裁剪

    /// 从文件加载图片并**应用 EXIF 方向**（手机照片必须处理，否则打印会颠倒/旋转）。
    /// NSImage.cgImage 不应用 EXIF（已实测），必须用 ImageIO 的带 transform 缩略图。
    static func loadImageOriented(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4000,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// 按像素矩形裁剪（原点在左上，EXIF 已应用后的视觉坐标）
    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let r = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard r.width >= 1, r.height >= 1 else { return nil }
        return image.cropping(to: r)
    }

    // MARK: - 图像变换（旋转 / 翻转镜像）

    /// 旋转（顺时针角度 0/90/180/270）+ 水平镜像 + 上下翻转，可任意组合。
    static func applyOrientation(_ image: CGImage,
                                 rotationDegrees: Int,
                                 flipH: Bool,
                                 flipV: Bool) -> CGImage? {
        let deg = ((rotationDegrees % 360) + 360) % 360
        let swap = (deg == 90 || deg == 270)
        let w = swap ? image.height : image.width
        let h = swap ? image.width : image.height
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        // CGContext 原点在左下（y 向上）→ 顺时针视觉旋转对应负角度
        ctx.rotate(by: -CGFloat(deg) * .pi / 180)
        ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2,
                                   y: -CGFloat(image.height) / 2,
                                   width: CGFloat(image.width),
                                   height: CGFloat(image.height)))
        return ctx.makeImage()
    }
}
