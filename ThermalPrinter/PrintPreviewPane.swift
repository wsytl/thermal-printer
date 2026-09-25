//
//  PrintPreviewPane.swift
//  B3 热敏打印 App —— 公共打印预览组件（三模式共用）
//

import SwiftUI
import AppKit

// MARK: - 公共打印预览（纸上的实际效果，物理比例正确）

struct PrintPreviewPane: View {
    let source: CGImage?
    let options: PrintEngine.RasterOptions
    var toggleable: Bool = true

    enum PreviewMode: String, CaseIterable, Identifiable {
        case source = "原图"
        case print = "打印效果"
        var id: String { rawValue }
    }

    @State private var mode: PreviewMode = .print
    @State private var preview: CGImage?
    @State private var rows = 0

    private var key: String {
        guard let s = source else { return "nil" }
        return "\(ObjectIdentifier(s).hashValue)-\(s.width)x\(s.height)"
            + "-\(Int(options.brightness * 100))-\(Int(options.contrast * 100))"
            + "-\(options.dithering)-\(mode.rawValue)"
    }

    var body: some View {
        VStack(spacing: 8) {
            if toggleable {
                Picker("", selection: $mode) {
                    ForEach(PreviewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.05))
                if let source {
                    if let shown = (mode == .print ? preview : source) {
                        Image(decorative: shown, scale: 1, orientation: .up)
                            .resizable()
                            .interpolation(mode == .print ? .none : .high)
                            // 关键：按"源图比例"显示。点阵纵向含 1.75 修正（行数偏多），
                            // 若按点阵自身像素比例显示会被上下拉伸 1.75 倍。
                            .aspectRatio(CGFloat(source.width) / CGFloat(source.height),
                                         contentMode: .fit)
                            .padding(8)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Text("暂无内容")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxHeight: .infinity)

            if let source {
                if mode == .print && rows > 0 {
                    Text("预计打印 \(fmt(PrintEngine.printWidthMM)) × \(fmt(CGFloat(rows) * PrintEngine.rowPitchMM)) mm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(source.width) × \(source.height) px")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: key) {
            guard mode == .print, let s = source else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)   // 去抖
            if Task.isCancelled { return }
            let r = PrintEngine.makePreview(image: s, options: options)
            preview = r.image
            rows = r.rows
        }
    }

    private func fmt(_ v: CGFloat) -> String { String(format: "%.1f", v) }
}
