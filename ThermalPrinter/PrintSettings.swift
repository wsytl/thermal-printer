//
//  PrintSettings.swift
//  B3 热敏打印 App —— 打印设置（三模式共用）
//
//  集中管理：打印效果（亮度/对比度/抖动/浓度）+ 文本排版（字体/字号/对齐/竖排/样式/间距）。
//  视图通过 @ObservedObject 读写；派生值 rasterOptions / textStyle 直接喂给 PrintEngine。
//

import AppKit
import Combine

@MainActor
final class PrintSettings: ObservableObject {

    // MARK: - 打印效果（三种模式共用）

    @Published var brightness = 0.0          // -0.6...0.6
    @Published var contrast = 0.0            // -0.6...0.6
    @Published var dithering = true          // Floyd–Steinberg 抖动
    /// 打印浓度固定值（1...5，越大越深）。实测官方默认 1 偏淡，中等 3 效果最好；
    /// 如需可调，改这里并恢复界面上的选择器。
    static let fixedDensity = 3

    // MARK: - 文本排版

    @Published var fontFamily = ""           // "" = 系统默认
    @Published var fontSize: CGFloat = 100   // 20...300
    @Published var alignIndex = 1            // 0 左 / 1 中 / 2 右
    @Published var vertical = false          // 竖排
    @Published var bold = false
    @Published var italic = false
    @Published var underline = false
    @Published var invert = false            // 反白（黑底白字）
    @Published var lineSpacing = 0.0         // -20...80
    @Published var letterSpacing = 0.0       // -8...40

    // MARK: - 派生值

    var rasterOptions: PrintEngine.RasterOptions {
        PrintEngine.RasterOptions(dithering: dithering,
                                  brightness: CGFloat(brightness),
                                  contrast: CGFloat(contrast),
                                  density: UInt8(max(1, min(5, Self.fixedDensity))))
    }

    var alignment: NSTextAlignment {
        [.left, .center, .right][max(0, min(2, alignIndex))]
    }

    var textStyle: PrintEngine.TextStyle {
        var s = PrintEngine.TextStyle()
        s.fontFamily = fontFamily
        s.fontSize = fontSize
        s.bold = bold
        s.italic = italic
        s.underline = underline
        s.alignment = alignment
        s.vertical = vertical
        s.lineSpacing = CGFloat(lineSpacing)
        s.letterSpacing = CGFloat(letterSpacing)
        s.invert = invert
        return s
    }

    /// 恢复打印效果默认值（浓度固定为中等，不在此处）
    func resetEffects() {
        brightness = 0
        contrast = 0
        dithering = true
    }
}
