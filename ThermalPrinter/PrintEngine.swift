//
//  PrintEngine.swift  (macOS)
//  B3 热敏打印机协议引擎 —— 核心：常量、打印序列、任务工厂
//
//  协议要点（已实测验证，详见 NOTES.md）：
//  - 打印头 576 点宽（300dpi 2 寸机）
//  - 序列：enable + awake + 浓度 + GS v 0 光栅 + stop
//    ⚠️ 不要发 0F 4A(lineDots)——会触发固件打印 "J扫J" 引导页
//  - 点阵：黑=1，每行 MSB-first，ceil(576/8)=72 字节/行
//  - 上下留白必须放进位图；底部留白需足够长才能出纸口
//  - 纵向行距比横向密 1.75 倍 → 图像高度预拉伸 1.75
//
//  本文件只放协议核心；其余按功能拆到 extension 文件：
//    PrintEngine+Raster.swift  光栅化 / 抖动 / 预览图
//    PrintEngine+Text.swift    文本渲染与字体样式
//    PrintEngine+Image.swift   图片加载 / 裁剪 / 旋转镜像
//

import AppKit
import CoreImage
import CoreText
import ImageIO

enum PrintEngine {


    // MARK: - 打印机参数（B3）

    static let paperDots = 576          // 打印头宽度（点）
    // 纵向行距修正（2026-09-25 照片+尺子交叉实测）：
    // 打印机横向 11.9 点/mm（300dpi），但纵向行距约 21 行/mm（0.047mm/行）——
    // 即每行位图只走纸约 0.047mm，所有图案会被打矮 1.75 倍。
    // 修复：生成点阵前把图像高度预拉伸 1.75 倍，打印出来比例即正确。
    static let verticalCorrection: CGFloat = 1.75
    // 物理尺寸换算（实测：横向 500 点 = 42mm → 0.084mm/点；纵向 = 横向/1.75）
    static let dotPitchMM: CGFloat = 0.084
    static var rowPitchMM: CGFloat { dotPitchMM / verticalCorrection }   // ≈0.048mm/行
    static var printWidthMM: CGFloat { CGFloat(paperDots) * dotPitchMM } // ≈48.4mm
    static let topBlankRows = 60        // 顶部空白行
    // 底部空白行：打印头到出纸口约有 2cm+ 的距离，任务结束后的留白若不够长
    // 会留在打印机内部（实测黑线在 118 行空白后仍看不见）。260 行 ≈ 2.2cm，
    // 保证撕纸时能看到约 1cm 空白边距。
    static let bottomBlankRows = 260

    // 传输参数
    static let chunkSize = 100          // 每片字节数

    /// 片间延时（实测标定 2026-09-25）：
    /// 打印机处理纯黑内容的消化速度 ≈ 4KB/s，模块缓冲 ≈ 24KB。
    /// - 短任务（≤50KB）6.6KB/s：缓冲可吸收差额，快且安全
    /// - 长任务（>50KB）4.0KB/s：必须 ≤ 消化速度，否则缓冲填满、尾部数据丢失
    ///   （表现为：图案打了但无底部留白、收不到 0xAA、任务挂起）
    static func interChunkDelay(for payloadBytes: Int) -> TimeInterval {
        if payloadBytes <= 50_000 {
            return 0.015   // ≈6.6KB/s
        }
        return 0.025       // ≈4.0KB/s
    }

    // MARK: - 光栅化选项

    struct RasterOptions {
        var threshold: Int = 128     // 二值化阈值
        var dithering: Bool = false  // Floyd–Steinberg 抖动（照片更细腻）
        var brightness: CGFloat = 0  // -1...1，正数变亮
        var contrast: CGFloat = 0    // -1...1，正数增强对比
        var density: UInt8 = 3       // 打印浓度 1...5（越大越深；官方默认 1）
    }

    // MARK: - 二维码生成（CoreImage → CGImage）

    static func makeQRCode(text: String, scale: CGFloat = 20) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")   // 最高纠错
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    // MARK: - 打印序列组装

    static func buildPrintData(raster: [UInt8], widthDots: Int, height: Int,
                               density: UInt8 = 3) -> Data {
        let wb = (widthDots + 7) / 8
        let totalHeight = height + topBlankRows + bottomBlankRows

        var d = Data()
        d.append(contentsOf: [0x10, 0xFF, 0xF1, 0x03])                 // enable
        d.append(Data(count: 1024))                                    // awake
        // 打印浓度（加热强度）：官方 setPrintThickness = 10 FF 10 00 <级别>
        // 级别越大越深（范围 1...5，官方默认 1，实测偏淡）
        d.append(contentsOf: [0x10, 0xFF, 0x10, 0x00, density])
        // ⚠️ 千万不要发官方的 0F 4A（lineDots）：实测它是"打印引导页"的触发命令，
        //    会导致每次打印前多出 "J扫J"（二维码 + "扫描二维码，查看按键的使用方法"）。
        //    我们的上下留白全部放在位图里，无需 lineDots（它本身也不走纸）。
        // GS v 0 (m=0，实测可用；加密 m 非压缩路径不校验)
        d.append(contentsOf: [0x1D, 0x76, 0x30, 0x00,
                              UInt8(wb & 0xFF), UInt8(wb >> 8),
                              UInt8(totalHeight & 0xFF), UInt8(totalHeight >> 8)])
        d.append(contentsOf: [UInt8](repeating: 0, count: wb * topBlankRows))    // 顶部空白行
        d.append(contentsOf: raster)                                             // 图案
        d.append(contentsOf: [UInt8](repeating: 0, count: wb * bottomBlankRows)) // 底部空白行
        d.append(contentsOf: [0x10, 0xFF, 0xF1, 0x45])                 // stop
        return d
    }

    // MARK: - 打印任务


    static func makePrintData(from image: CGImage,
                              options: RasterOptions = RasterOptions()) -> (data: Data, height: Int)? {
        let (raster, height) = rasterize(image: image, options: options)
        guard height > 0 else { return nil }
        return (buildPrintData(raster: raster, widthDots: paperDots, height: height,
                               density: options.density), height)
    }

    static func makeQRPrintData(text: String,
                                options: RasterOptions = RasterOptions()) -> (data: Data, height: Int)? {
        guard let qr = makeQRCode(text: text) else { return nil }
        // 二维码自带 4 模块白边（quiet zone），整幅缩放到纸宽
        return makePrintData(from: qr, options: options)
    }

    static func makeTextPrintData(text: String,
                                  style: TextStyle = TextStyle(),
                                  options: RasterOptions = RasterOptions()) -> (data: Data, height: Int)? {
        guard let img = makeTextImage(text: text, style: style) else { return nil }
        let (raster, height) = rasterize(image: img, options: options)
        guard height > 0 else { return nil }
        return (buildPrintData(raster: raster, widthDots: paperDots, height: height,
                               density: options.density), height)
    }

    /// 兼容旧调用（仅字号 + 对齐）
    static func makeTextPrintData(text: String,
                                  fontSize: CGFloat,
                                  alignment: NSTextAlignment,
                                  options: RasterOptions = RasterOptions()) -> (data: Data, height: Int)? {
        var s = TextStyle()
        s.fontSize = fontSize
        s.alignment = alignment
        return makeTextPrintData(text: text, style: s, options: options)
    }
}
