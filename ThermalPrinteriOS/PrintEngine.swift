//
//  PrintEngine.swift
//  B3 热敏打印机协议引擎（纯逻辑，无蓝牙依赖）
//
//  协议要点（已实测验证，详见 NOTES.md）：
//  - 打印头 576 点宽（300dpi 2 寸机）
//  - 序列：enable + awake + GS v 0 光栅 + stop
//  - 点阵：黑=1，每行 MSB-first，ceil(576/8)=72 字节/行
//  - 上下留白必须放进位图；不要发 0F 4A(lineDots)——它会触发固件打印 "J扫J" 引导页
//

import UIKit
import CoreImage

enum PrintEngine {

    // MARK: - 打印机参数（B3）

    static let paperDots = 576          // 打印头宽度（点）
    static let dotsPerCm = 118          // 300dpi 下 1cm ≈ 118 点
    static let topBlankRows = 60        // 顶部空白行（实测顶部实际略偏大）
    static let bottomBlankRows = 118    // 底部空白行 ≈ 1cm，保证图案完全出纸
    static let ditherThreshold = 128    // 灰度二值化阈值

    // 传输参数（单张可靠且快的组合）
    static let chunkSize = 100          // 每片字节数（MTU 240 内安全）
    static let interChunkDelay = 0.012  // 片间延时（秒），≈8.3KB/s

    // MARK: - 二维码生成（CoreImage）

    static func qrCodeImage(text: String, scale: CGFloat = 8) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")   // 最高纠错
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return UIImage(ciImage: scaled)
    }

    // MARK: - 图片 → 1-bit 点阵（黑=1，MSB first）

    /// 把 UIImage 缩放到 widthDots 宽（保持比例），灰度化 + 阈值二值化 + 打包。
    /// 返回 (raster, height)；raster 长度 = ceil(widthDots/8) * height
    static func rasterize(image: UIImage,
                          widthDots: Int = paperDots,
                          threshold: Int = ditherThreshold) -> (raster: [UInt8], height: Int) {
        // 确保有可用的 CGImage（CIImage-backed 的 UIImage 需要先渲染成位图）
        let workImage: UIImage
        if image.cgImage != nil {
            workImage = image
        } else {
            workImage = UIGraphicsImageRenderer(size: image.size).image { ctx in
                ctx.cgContext.setFillColor(UIColor.white.cgColor)
                ctx.cgContext.fill(CGRect(origin: .zero, size: image.size))
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
        }

        let width = max(1, widthDots)
        let scale = CGFloat(width) / max(1, workImage.size.width)
        let height = max(1, Int((workImage.size.height * scale).rounded()))
        let wb = (width + 7) / 8
        var raster = [UInt8](repeating: 0, count: wb * height)

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return (raster, height)
        }
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        if let cg = workImage.cgImage {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let raw = ctx.data else { return (raster, height) }
        let buf = raw.bindMemory(to: UInt8.self, capacity: width * height)

        // CGContext 原点在左下，行号从底到顶 → 翻转后行序为"顶部在前"
        for row in 0..<height {
            let srcRow = height - 1 - row
            var byte: UInt8 = 0
            for col in 0..<width {
                let v = Int(buf[srcRow * width + col])
                if v < threshold {
                    byte |= UInt8(1 << (7 - (col % 8)))
                }
                if col % 8 == 7 {
                    raster[row * wb + col / 8] = byte
                    byte = 0
                }
            }
            if width % 8 != 0 {
                raster[row * wb + width / 8] = byte
            }
        }
        return (raster, height)
    }

    // MARK: - 打印序列组装

    /// enable + awake + GS v 0 + 位图(含上下空白行) + stop
    /// ⚠️ 不要加官方 0F 4A(lineDots)：实测它会触发固件打印 "J扫J" 引导页
    static func buildPrintData(raster: [UInt8], widthDots: Int, height: Int) -> Data {
        let wb = (widthDots + 7) / 8
        let totalHeight = height + topBlankRows + bottomBlankRows

        var d = Data()
        d.append(contentsOf: [0x10, 0xFF, 0xF1, 0x03])                 // enable
        d.append(Data(count: 1024))                                    // awake
        // GS v 0 (m=0，实测可用；加密 m 非压缩路径不校验)
        d.append(contentsOf: [0x1D, 0x76, 0x30, 0x00,
                              UInt8(wb & 0xFF), UInt8(wb >> 8),
                              UInt8(totalHeight & 0xFF), UInt8(totalHeight >> 8)])
        d.append(contentsOf: [UInt8](repeating: 0, count: wb * topBlankRows))    // 顶部空白行
        d.append(contentsOf: raster)                                             // 图案
        d.append(contentsOf: [UInt8](repeating: 0, count: wb * bottomBlankRows)) // 底部空白行
        d.append(contentsOf: [0x10, 0xFF, 0xF1, 0x45])                  // stop
        return d
    }

    // MARK: - 打印任务（图片 → 完整数据）

    static func makePrintData(from image: UIImage) -> (data: Data, height: Int)? {
        let (raster, height) = rasterize(image: image)
        guard height > 0 else { return nil }
        let data = buildPrintData(raster: raster, widthDots: paperDots, height: height)
        return (data, height)
    }

    static func makeQRPrintData(text: String) -> (data: Data, height: Int)? {
        guard let qr = qrCodeImage(text: text) else { return nil }
        // 二维码四周留少量白边，整体再缩放到纸宽 576 点
        let side = qr.size.width
        let canvasSide = side * 1.15
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasSide, height: canvasSide))
        let padded = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide))
            qr.draw(in: CGRect(x: (canvasSide - side) / 2, y: (canvasSide - side) / 2,
                               width: side, height: side))
        }
        return makePrintData(from: padded)
    }
}
