//
//  QRPrintView.swift
//  B3 热敏打印 App —— 二维码打印模式
//
//  输入内容（网址/文字/WiFi/名片）→ 生成二维码 → 右侧公共打印预览。
//

import SwiftUI
import AppKit

struct QRPrintView: View {
    @ObservedObject var settings: PrintSettings
    let canPrint: Bool
    let enqueue: (Data, String, String, Int) -> Void

    @State private var input = "https://"

    private let examples: [(label: String, value: String)] = [
        ("网址", "https://www.example.com"),
        ("WiFi", "WIFI:T:WPA;S:MyWiFi;P:12345678;;"),
        ("名片", "BEGIN:VCARD\nVERSION:3.0\nFN:张三\nTEL:13800000000\nEND:VCARD"),
        ("纯文本", "你好，热敏打印！"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("输入内容：网址、文字、联系方式等", text: $input)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    Text("快速示例").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(examples, id: \.label) { item in
                            Button(item.label) { input = item.value }
                                .controlSize(.small)
                        }
                    }
                }

                Text("打印尺寸约 48×48mm；纠错等级 H（轻微磨损也能扫）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button { printQR() } label: {
                        Label("打印二维码", systemImage: "printer")
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
        input.trimmingCharacters(in: .whitespaces)
    }

    private var preview: CGImage? {
        guard !trimmed.isEmpty else { return nil }
        return PrintEngine.makeQRCode(text: trimmed)
    }

    private func printQR() {
        guard !trimmed.isEmpty,
              let job = PrintEngine.makeQRPrintData(text: trimmed, options: settings.rasterOptions)
        else { return }
        enqueue(job.data, "二维码", String(trimmed.prefix(24)), job.height)
    }
}
