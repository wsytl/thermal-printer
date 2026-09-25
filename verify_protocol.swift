//
//  verify_protocol.swift — 打印协议参数回归自检
//
//  用途：任何改动后跑一遍，确认三种打印模式（文本/二维码/图片）生成的
//        打印序列仍然满足已验证的协议参数，避免回归。
//
//  编译运行：
//    swiftc -O ThermalPrinter/PrintEngine.swift verify_protocol.swift -o /tmp/verify_protocol && /tmp/verify_protocol
//
//  自检项：
//    - 序列结构：enable + awake(1024) + lineDots(top) + GS v 0 + 光栅 + lineDots(bottom) + stop
//    - 每行字节数 72（576 点）
//    - GS v 0 高度字段 = 图案行数 + 顶部 60 + 底部 260
//    - 数据长度自洽
//    - 纵向 1.75 修正生效
//    - 传输速率分档（≤50KB → 15ms；>50KB → 25ms）
//

import Foundation
import AppKit

@main
enum VerifyProtocol {

    static var failures = 0

    static func check(_ cond: Bool, _ msg: String) {
        print(cond ? "  ✅ \(msg)" : "  ❌ \(msg)")
        if !cond { failures += 1 }
    }

    static let wb = 72            // 576 / 8
    static let topBlank = 60
    static let bottomBlank = 260

    static func verify(_ name: String, _ data: Data, _ height: Int, expectHeight: Int? = nil) {
        print("【\(name)】payload \(data.count) 字节，图案 \(height) 行")
        let b = [UInt8](data)

        check(b.count > 1036, "长度足够（\(b.count) 字节）")
        guard b.count > 1036 else { return }

        check(Array(b[0..<4]) == [0x10, 0xFF, 0xF1, 0x03], "以 enable (10 FF F1 03) 开头")
        check(b[4..<1028].allSatisfy { $0 == 0 }, "含 1024 字节 awake")

        // 打印浓度命令 setPrintThickness = 10 FF 10 00 <1...5>
        let th = Array(b[1028..<1033])
        check(th[0] == 0x10 && th[1] == 0xFF && th[2] == 0x10 && th[3] == 0x00,
              "含浓度命令 (10 FF 10 00)")
        check((1...5).contains(Int(th[4])), "浓度级别 \(th[4]) 在 1...5 范围")

        // ⚠️ 关键防回归：0F 4A（官方 lineDots）会触发固件打印 "J扫J" 引导页，绝不能出现
        var foundLineDots = false
        for i in 0..<(b.count - 1) where b[i] == 0x0F && b[i + 1] == 0x4A {
            foundLineDots = true
            break
        }
        check(!foundLineDots, "不含 0F 4A（lineDots 会触发 J扫J 引导页）")

        let gs = Array(b[1033..<1041])
        check(gs[0] == 0x1D && gs[1] == 0x76 && gs[2] == 0x30 && gs[3] == 0x00,
              "GS v 0 头 (m=0)")
        let rowBytes = Int(gs[4]) | (Int(gs[5]) << 8)
        check(rowBytes == wb, "每行 \(rowBytes) 字节（应为 \(wb) = 576 点）")
        let total = Int(gs[6]) | (Int(gs[7]) << 8)
        check(total == height + topBlank + bottomBlank,
              "高度字段 \(total) = 图案 \(height) + 顶 \(topBlank) + 底 \(bottomBlank)")

        let tail = Array(b.suffix(4))
        check(tail == [0x10, 0xFF, 0xF1, 0x45], "以 stop (10 FF F1 45) 结尾")

        // 头 1041（enable 4 + awake 1024 + 浓度 5 + GS v 0 头 8）+ 光栅 + 尾 4（stop）
        check(data.count == 1045 + wb * total,
              "数据长度自洽：\(data.count) = 1045 + \(wb)×\(total)")

        let delay = PrintEngine.interChunkDelay(for: data.count)
        let expected: TimeInterval = data.count <= 50_000 ? 0.015 : 0.025
        check(delay == expected,
              "速率分档 \(String(format: "%.3f", delay))s / 100 字节（\(data.count) 字节 → \(expected == 0.015 ? "快档" : "长图慢档")）")

        if let eh = expectHeight {
            check(height == eh, "图案行数 \(height)（应为 \(eh)，含纵向 1.75 修正）")
        }
    }

    /// 取灰度缓冲（row 0 = 顶部）
    static func gray(_ img: CGImage) -> (buf: [UInt8], w: Int, h: Int) {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 255, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (buf, w, h)
    }

    /// 字形包围盒（在整幅图中定位内容）
    static func glyphBox(_ g: (buf: [UInt8], w: Int, h: Int)) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        var x0 = g.w, y0 = g.h, x1 = -1, y1 = -1
        for y in 0..<g.h {
            for x in 0..<g.w where g.buf[y * g.w + x] < 128 {
                x0 = min(x0, x); y0 = min(y0, y)
                x1 = max(x1, x); y1 = max(y1, y)
            }
        }
        return (x0, y0, x1, y1)
    }

    /// 字形包围盒某条边缘带的暗像素覆盖率：0=上 1=下 2=左 3=右
    static func edgeCoverage(_ g: (buf: [UInt8], w: Int, h: Int), _ edge: Int) -> Double {
        let b = glyphBox(g)
        guard b.x1 > b.x0, b.y1 > b.y0 else { return 0 }
        let bw = b.x1 - b.x0 + 1, bh = b.y1 - b.y0 + 1
        let bandX = max(2, bw / 8), bandY = max(2, bh / 8)
        var dark = 0, total = 0
        for y in b.y0...b.y1 {
            for x in b.x0...b.x1 {
                let inside: Bool
                switch edge {
                case 0: inside = y < b.y0 + bandY
                case 1: inside = y > b.y1 - bandY
                case 2: inside = x < b.x0 + bandX
                default: inside = x > b.x1 - bandX
                }
                guard inside else { continue }
                total += 1
                if g.buf[y * g.w + x] < 128 { dark += 1 }
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }

    /// 变换方向自检：用正立 "F"（竖笔在左、顶横在上）
    static func checkTransforms() {
        print("\n— 图片变换方向自检 —")
        guard let src = PrintEngine.makeTextImage(text: "F", fontSize: 140, alignment: .center) else {
            check(false, "源图生成"); return
        }
        let o = gray(src)
        check(edgeCoverage(o, 2) > 0.7, "原始 F 左边覆盖率高 \(Int(edgeCoverage(o, 2) * 100))%（竖笔在左 >70%）")
        check(edgeCoverage(o, 0) > 0.7, "原始 F 上边覆盖率高 \(Int(edgeCoverage(o, 0) * 100))%（顶横在上 >70%）")

        if let fh = PrintEngine.applyOrientation(src, rotationDegrees: 0, flipH: true, flipV: false) {
            let g = gray(fh)
            check(edgeCoverage(g, 3) > 0.7, "左右镜像后右边覆盖率高 \(Int(edgeCoverage(g, 3) * 100))%（竖笔移到右 >70%）")
        }
        if let fv = PrintEngine.applyOrientation(src, rotationDegrees: 0, flipH: false, flipV: true) {
            let g = gray(fv)
            check(edgeCoverage(g, 1) > 0.7, "上下翻转后下边覆盖率高 \(Int(edgeCoverage(g, 1) * 100))%（顶横移到下 >70%）")
        }
        if let r90 = PrintEngine.applyOrientation(src, rotationDegrees: 90, flipH: false, flipV: false) {
            let g = gray(r90)
            check(g.w == o.h && g.h == o.w, "右转 90° 后宽高互换 \(g.w)×\(g.h)")
            check(edgeCoverage(g, 3) > 0.7, "右转 90°（顺时针）后右边覆盖率高 \(Int(edgeCoverage(g, 3) * 100))%（原顶横转到右 >70%）")
        }
        if let r270 = PrintEngine.applyOrientation(src, rotationDegrees: 270, flipH: false, flipV: false) {
            let g = gray(r270)
            check(edgeCoverage(g, 2) > 0.7, "左转 90° 后左边覆盖率高 \(Int(edgeCoverage(g, 2) * 100))%（原顶横转到左 >70%）")
        }
        // 恒等式：镜像两次 / 旋转四次 应还原
        if let twice = PrintEngine.applyOrientation(src, rotationDegrees: 0, flipH: true, flipV: false)
            .flatMap({ PrintEngine.applyOrientation($0, rotationDegrees: 0, flipH: true, flipV: false) }) {
            let g = gray(twice)
            check(g.buf == o.buf, "镜像两次还原原图")
        }
        if let four = (0..<4).reduce(Optional(src), { acc, _ in
            acc.flatMap { PrintEngine.applyOrientation($0, rotationDegrees: 90, flipH: false, flipV: false) }
        }) {
            let g = gray(four)
            check(g.buf == o.buf, "旋转 4×90° 还原原图")
        }
    }

    /// 文本样式自检：竖排应逐字堆叠、反白应为黑底白字
    static func checkTextStyles() {
        print("\n— 文本样式自检 —")
        let sample = "热敏打印ABC"
        // 横排基准
        guard let h = PrintEngine.makeTextImage(text: sample, style: PrintEngine.TextStyle()) else {
            check(false, "横排文本图生成"); return
        }
        let gh = gray(h)
        let bh = glyphBox(gh)
        let hRatio = Double(bh.y1 - bh.y0 + 1) / Double(max(1, bh.x1 - bh.x0 + 1))

        var vs = PrintEngine.TextStyle()
        vs.vertical = true
        guard let v = PrintEngine.makeTextImage(text: sample, style: vs) else {
            check(false, "竖排文本图生成"); return
        }
        let gv = gray(v)
        let bv = glyphBox(gv)
        let vRatio = Double(bv.y1 - bv.y0 + 1) / Double(max(1, bv.x1 - bv.x0 + 1))
        check(vRatio > 3.0, "竖排内容高宽比 \(String(format: "%.1f", vRatio))（应 >3，横排为 \(String(format: "%.2f", hRatio))）")

        var istyle = PrintEngine.TextStyle()
        istyle.invert = true
        guard let inv = PrintEngine.makeTextImage(text: sample, style: istyle) else {
            check(false, "反白文本图生成"); return
        }
        let gi = gray(inv)
        let dark = gi.buf.filter { $0 < 128 }.count
        let frac = Double(dark) / Double(gi.buf.count)
        check(frac > 0.5, "反白暗底占比 \(Int(frac * 100))%（应 >50%，黑底白字）")

        // 粗体应比常规更粗（同字号下暗像素更多或换行更早）
        var bs = PrintEngine.TextStyle()
        bs.bold = true
        if let b = PrintEngine.makeTextImage(text: sample, style: bs) {
            let gb = gray(b)
            let bDark = gb.buf.filter { $0 < 128 }.count
            let hDark = gh.buf.filter { $0 < 128 }.count
            check(bDark != hDark, "粗体渲染与常规不同（粗体 \(bDark) vs 常规 \(hDark) 暗像素）")
        }
    }

    static func main() {
        print("=== B3 热敏打印协议参数自检 ===\n")

        // 0) 文本朝向（防倒置回归）：用正立 "F" 验证——顶部应整条横笔，底部只有竖笔
        print("— 文本朝向自检 —")
        if let img = PrintEngine.makeTextImage(text: "F", fontSize: 120, alignment: .center) {
            let w = img.width, h = img.height
            var buf = [UInt8](repeating: 255, count: w * h)
            let cs = CGColorSpaceCreateDeviceGray()
            buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            // 该缓冲行序：row 0 = 图像顶部
            func isDark(_ x: Int, _ y: Int) -> Bool { buf[y * w + x] < 128 }
            var minY = h, maxY = -1, minX = w, maxX = -1
            for y in 0..<h {
                for x in 0..<w where isDark(x, y) {
                    minY = min(minY, y); maxY = max(maxY, y)
                    minX = min(minX, x); maxX = max(maxX, x)
                }
            }
            if maxY > minY && maxX > minX {
                func coverage(_ y: Int) -> Double {
                    var n = 0
                    for x in minX...maxX where isDark(x, y) { n += 1 }
                    return Double(n) / Double(maxX - minX + 1)
                }
                let top = coverage(minY + 2)
                let bottom = coverage(maxY - 2)
                check(top > 0.6, "字形首行横笔覆盖率 \(Int(top * 100))%（正立 F 顶部应为整条横笔 >60%）")
                check(bottom < 0.4, "字形末行覆盖率 \(Int(bottom * 100))%（正立 F 底部只有竖笔 <40%）")
            } else {
                check(false, "字形非空")
            }
        } else {
            check(false, "文本图生成")
        }

        // 0.5) 图片变换方向
        checkTransforms()

        // 0.6) 文本样式
        checkTextStyles()

        // 1) 文本
        print("\n— 文本打印 —")
        if let job = PrintEngine.makeTextPrintData(text: "你好，热敏打印！\nTHERMAL B3",
                                                   fontSize: 100, alignment: .center) {
            verify("文本 100pt 居中", job.data, job.height)
        } else {
            check(false, "文本打印数据生成")
        }

        // 2) 二维码
        print("\n— 二维码打印 —")
        if let job = PrintEngine.makeQRPrintData(text: "https://www.example.com") {
            verify("二维码", job.data, job.height)
        } else {
            check(false, "二维码打印数据生成")
        }

        // 3) 图片（含抖动，纵向 1.75 修正：2179 × 576/805 × 1.75 = 2728）
        print("\n— 图片打印 —")
        let url = URL(fileURLWithPath: "she.jpg")
        if let img = PrintEngine.loadImageOriented(from: url) {
            check(img.width == 805 && img.height == 2179,
                  "EXIF 处理后尺寸 \(img.width)×\(img.height)（应为 805×2179）")
            var opts = PrintEngine.RasterOptions()
            opts.dithering = true
            if let job = PrintEngine.makePrintData(from: img, options: opts) {
                verify("图片 + 抖动", job.data, job.height, expectHeight: 2728)
            } else {
                check(false, "图片打印数据生成")
            }
        } else {
            print("  ⚠️ 找不到 she.jpg，跳过图片测试")
        }

        print("\n=== \(failures == 0 ? "全部通过 ✅" : "有 \(failures) 项失败 ❌") ===")
        exit(failures == 0 ? 0 : 1)
    }
}
