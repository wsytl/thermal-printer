//
//  PrintEngine+Raster.swift
//  B3 热敏打印机 —— 光栅化 / 抖动 / 打印预览图
//
//  说明：CGImage → 1bit 点阵；含亮度对比度、Floyd–Steinberg 抖动、点阵还原成预览图
//

import AppKit
import CoreImage
import CoreText
import ImageIO

extension PrintEngine {

    // MARK: - CGImage → 1-bit 点阵（黑=1，MSB first）

    /// 缩放到 widthDots 宽（保持比例，含纵向 1.75 修正），灰度化 + 二值化 + 打包。
    /// 返回 (raster, height)；raster 长度 = ceil(widthDots/8) * height；行序：顶部在前。
    static func rasterize(image: CGImage,
                          widthDots: Int = paperDots,
                          options: RasterOptions = RasterOptions()) -> (raster: [UInt8], height: Int) {
        let width = max(1, widthDots)
        let scale = CGFloat(width) / CGFloat(image.width)
        // 高度预拉伸 verticalCorrection 倍，抵消打印机纵向行距偏密的压缩
        let height = max(1, Int((CGFloat(image.height) * scale * verticalCorrection).rounded()))
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
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = ctx.data else { return (raster, height) }
        let buf = raw.bindMemory(to: UInt8.self, capacity: width * height)

        // 亮度 / 抖动预处理（原地修改 buf）
        if options.brightness != 0 || options.dithering {
            preprocess(buf, width: width, height: height, options: options)
        }

        // CGBitmapContext 的内存行序是"顶行在前"（row 0 = 图像顶部），
        // 直接按行取即可，行序无需翻转（2026-09-25 实测：此前翻转导致整幅 180° 倒置打印）
        for row in 0..<height {
            let srcRow = row
            var byte: UInt8 = 0
            for col in 0..<width {
                if Int(buf[srcRow * width + col]) < options.threshold {
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

    /// 亮度/对比度调整 + 二值化；开启抖动时用 Floyd–Steinberg 误差扩散（热敏纸照片更细腻）。
    private static func preprocess(_ buf: UnsafeMutablePointer<UInt8>,
                                   width: Int, height: Int, options: RasterOptions) {
        let total = width * height
        let gain = 1.0 + Double(options.contrast)          // 对比度增益
        let offset = Double(options.brightness) * 255.0    // 亮度偏移
        let threshold = options.threshold
        // v -> 对比度拉伸 + 亮度平移
        @inline(__always) func adjust(_ v: Int) -> Int {
            let x = (Double(v) - 128.0) * gain + 128.0 + offset
            return min(max(Int(x.rounded()), 0), 255)
        }
        if !options.dithering {
            for i in 0..<total {
                buf[i] = adjust(Int(buf[i])) < threshold ? 0 : 255
            }
            return
        }
        var err = [Int](repeating: 0, count: total)
        for row in 0..<height {
            for col in 0..<width {
                let idx = row * width + col
                let val = min(max(adjust(Int(buf[idx])) + err[idx], 0), 255)
                let newVal: Int = val < threshold ? 0 : 255
                buf[idx] = UInt8(newVal)
                let e = val - newVal
                if col + 1 < width { err[idx + 1] += e * 7 / 16 }
                if row + 1 < height {
                    if col > 0 { err[idx + width - 1] += e * 3 / 16 }
                    err[idx + width] += e * 5 / 16
                    if col + 1 < width { err[idx + width + 1] += e * 1 / 16 }
                }
            }
        }
    }

    // MARK: - 点阵 → 预览图（打印效果 WYSIWYG）

    private static let bitExpand: [[UInt8]] = (0...255).map { b in
        (0..<8).map { i in ((b >> (7 - i)) & 1) == 1 ? UInt8(0) : UInt8(255) }
    }

    /// 把 1 位点阵还原成灰度 CGImage，用于在界面上预览"打印出来是什么样"。
    static func previewImage(fromRaster raster: [UInt8], widthDots: Int, height: Int) -> CGImage? {
        let wb = (widthDots + 7) / 8
        guard height > 0, raster.count >= wb * height, widthDots % 8 == 0 else { return nil }
        var buf = [UInt8](repeating: 255, count: widthDots * height)
        buf.withUnsafeMutableBufferPointer { dst in
            for y in 0..<height {
                let srcBase = y * wb
                let dstBase = y * widthDots
                for bx in 0..<wb {
                    let expanded = bitExpand[Int(raster[srcBase + bx])]
                    let off = dstBase + bx * 8
                    dst[off] = expanded[0]; dst[off + 1] = expanded[1]
                    dst[off + 2] = expanded[2]; dst[off + 3] = expanded[3]
                    dst[off + 4] = expanded[4]; dst[off + 5] = expanded[5]
                    dst[off + 6] = expanded[6]; dst[off + 7] = expanded[7]
                }
            }
        }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(buf) as CFData),
              let img = CGImage(width: widthDots, height: height,
                                bitsPerComponent: 8, bitsPerPixel: 8,
                                bytesPerRow: widthDots, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return img
    }

    /// 按当前选项生成预览（含纵向 1.75 修正），返回预览图与点阵行数
    static func makePreview(image: CGImage, options: RasterOptions) -> (image: CGImage?, rows: Int) {
        let (raster, height) = rasterize(image: image, options: options)
        return (previewImage(fromRaster: raster, widthDots: paperDots, height: height), height)
    }
}
