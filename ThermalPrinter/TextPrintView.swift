//
//  TextPrintView.swift
//  B3 热敏打印 App —— 文本打印模式
//
//  排版（横排/竖排）、对齐、字体、字号、行距字距、粗斜体/下划线/反白；
//  右侧公共打印预览。打印内容由本视图自行构建后交给上层入队。
//

import SwiftUI
import AppKit

struct TextPrintView: View {
    @ObservedObject var settings: PrintSettings
    let canPrint: Bool
    /// (打印序列, 类型, 标题, 点阵行数)
    let enqueue: (Data, String, String, Int) -> Void

    @State private var textInput = "你好，热敏打印！"

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 10) {
                TextEditor(text: $textInput)
                    .font(.system(size: 15))
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3)))

                // 排版 / 对齐 / 字体
                HStack(spacing: 10) {
                    Picker("排版", selection: $settings.vertical) {
                        Text("横排").tag(false)
                        Text("竖排").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 104)

                    Picker("对齐", selection: $settings.alignIndex) {
                        Image(systemName: "text.alignleft").tag(0)
                        Image(systemName: "text.aligncenter").tag(1)
                        Image(systemName: "text.alignright").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 108)

                    Picker("字体", selection: $settings.fontFamily) {
                        ForEach(PrintEngine.TextStyle.fontChoices, id: \.family) { item in
                            Text(item.label).tag(item.family)
                        }
                    }
                    .frame(maxWidth: 170)
                }

                // 字号
                HStack(spacing: 8) {
                    Text("字号").font(.caption)
                    Slider(value: $settings.fontSize, in: 20...300)
                    Text("\(Int(settings.fontSize))")
                        .font(.caption).monospacedDigit().frame(width: 32)
                    ForEach([("小", 60.0), ("中", 100.0), ("大", 150.0), ("特大", 220.0)], id: \.0) { item in
                        Button(item.0) { settings.fontSize = CGFloat(item.1) }
                            .controlSize(.mini)
                    }
                }

                // 行距 / 字距
                HStack(spacing: 8) {
                    Text("行距").font(.caption)
                    Slider(value: $settings.lineSpacing, in: -20...80).frame(maxWidth: 130)
                    Text("字距").font(.caption)
                    Slider(value: $settings.letterSpacing, in: -8...40).frame(maxWidth: 130)
                }

                // 样式 + 打印
                HStack(spacing: 12) {
                    Toggle("粗体", isOn: $settings.bold).toggleStyle(.checkbox).controlSize(.small)
                    Toggle("斜体", isOn: $settings.italic).toggleStyle(.checkbox).controlSize(.small)
                    Toggle("下划线", isOn: $settings.underline).toggleStyle(.checkbox).controlSize(.small)
                    Toggle("反白", isOn: $settings.invert).toggleStyle(.checkbox).controlSize(.small)
                    Spacer()
                    Button { printText() } label: {
                        Label("打印文本", systemImage: "printer")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPrint || trimmed.isEmpty)
                }
                Spacer()
            }
            .padding(12)

            Divider()

            PrintPreviewPane(source: preview, options: settings.rasterOptions)
                .frame(width: 250)
                .padding(12)
        }
    }

    // MARK: - 私有

    private var trimmed: String {
        textInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var preview: CGImage? {
        guard !trimmed.isEmpty else { return nil }
        return PrintEngine.makeTextImage(text: trimmed, style: settings.textStyle)
    }

    private func printText() {
        guard !trimmed.isEmpty,
              let job = PrintEngine.makeTextPrintData(text: trimmed,
                                                      style: settings.textStyle,
                                                      options: settings.rasterOptions)
        else { return }
        enqueue(job.data, "文本", String(trimmed.prefix(24)), job.height)
    }
}
