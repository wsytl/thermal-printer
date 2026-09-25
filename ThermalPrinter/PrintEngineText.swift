//
//  PrintEngine+Text.swift
//  B3 热敏打印机 —— 文本渲染与字体样式
//
//  说明：CoreText 绘制（坐标系与裸 CGContext 一致，字形正立）；支持竖排/反白/行距字距等
//

import AppKit
import CoreImage
import CoreText
import ImageIO

extension PrintEngine {

    // MARK: - 文本渲染（多行自动换行 + 对齐 + 字体样式）

    /// 文本样式（字体 / 字号 / 粗斜体 / 下划线 / 行距字距 / 竖排 / 反白）
    struct TextStyle {
        var fontFamily: String = ""            // "" = 系统默认
        var fontSize: CGFloat = 100
        var bold = false
        var italic = false
        var underline = false
        var alignment: NSTextAlignment = .center
        var vertical = false                   // 竖排（逐字换行）
        var lineSpacing: CGFloat = 0           // 额外行距（点）
        var letterSpacing: CGFloat = 0         // 字距（点）
        var invert = false                     // 反白（白字黑底）

        /// 界面用字体列表（均为 macOS 自带、支持中文）
        static let fontChoices: [(label: String, family: String)] = [
            ("系统默认", ""),
            ("苹方（黑体）", "PingFang SC"),
            ("宋体", "Songti SC"),
            ("楷体", "Kaiti SC"),
            ("冬青黑体", "Hiragino Sans GB"),
            ("华文黑体", "STHeiti"),
            ("圆体", "Yuanti SC"),
            ("等宽 Menlo", "Menlo"),
            ("Times 衬线", "Times New Roman"),
            ("Arial", "Arial"),
        ]
    }

    private static func resolveFont(_ style: TextStyle) -> NSFont {
        var font: NSFont
        if !style.fontFamily.isEmpty, let f = NSFont(name: style.fontFamily, size: style.fontSize) {
            font = f
        } else {
            font = NSFont.systemFont(ofSize: style.fontSize)
        }
        if style.bold || style.italic {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if style.bold { traits.insert(.bold) }
            if style.italic { traits.insert(.italic) }
            let desc = font.fontDescriptor.withSymbolicTraits(traits)
            font = NSFont(descriptor: desc, size: style.fontSize) ?? font
        }
        return font
    }

    /// 竖排：每个字单独成行（保留原有换行为空行分隔）
    private static func verticalize(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.map(String.init).joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    static func makeTextImage(text: String,
                              style: TextStyle = TextStyle(),
                              widthDots: Int = paperDots) -> CGImage? {
        let margin: CGFloat = 40                    // 左右留白（点）
        let pad: CGFloat = 20                       // 上下留白（点）
        let contentWidth = CGFloat(widthDots) - margin * 2
        guard contentWidth > 40 else { return nil }
        let body = style.vertical ? verticalize(text) : text

        let para = NSMutableParagraphStyle()
        para.alignment = style.alignment
        para.lineSpacing = style.lineSpacing
        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolveFont(style),
            .foregroundColor: style.invert ? NSColor.white : NSColor.black,
            .paragraphStyle: para,
        ]
        if style.letterSpacing != 0 { attrs[.kern] = style.letterSpacing }
        if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }

        let attrStr = NSAttributedString(string: body, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)

        // 先量出换行后需要的高度
        let constraint = CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, 0), nil, constraint, nil)
        let textHeight = max(ceil(suggested.height), style.fontSize)
        let height = max(Int(textHeight + pad * 2), 64)

        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil,
                                  width: widthDots, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // 背景：反白时整块黑底（含内边距），否则纯白
        if style.invert {
            ctx.setFillColor(gray: 1.0, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(widthDots), height: CGFloat(height)))
            ctx.setFillColor(gray: 0.0, alpha: 1.0)
            let blockH = min(textHeight, CGFloat(height) - pad * 2)
            ctx.fill(CGRect(x: margin - 10, y: pad - 10,
                            width: contentWidth + 20, height: blockH + 20))
        } else {
            ctx.setFillColor(gray: 1.0, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(widthDots), height: CGFloat(height)))
        }

        // 用 CoreText 直接绘制：它工作在 CGContext 原生坐标系（原点左下），
        // 字形正立、首行在矩形顶部 → 内存行序即"顶部在前"，与 rasterize 期望一致。
        // （不要用 NSGraphicsContext(flipped:)，其坐标约定与裸 CGContext 不一致，会打出倒置文字）
        let rect = CGRect(x: margin, y: pad,
                          width: contentWidth, height: CGFloat(height) - pad * 2)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    /// 兼容旧调用（仅字号 + 对齐）
    static func makeTextImage(text: String,
                              fontSize: CGFloat,
                              alignment: NSTextAlignment,
                              widthDots: Int = paperDots) -> CGImage? {
        var s = TextStyle()
        s.fontSize = fontSize
        s.alignment = alignment
        return makeTextImage(text: text, style: s, widthDots: widthDots)
    }
}
