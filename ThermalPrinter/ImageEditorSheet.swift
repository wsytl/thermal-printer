//
//  ImageEditorSheet.swift
//  B3 热敏打印 App —— 图片编辑器（旋转/镜像/翻转/裁剪/亮度对比度）
//

import SwiftUI
import AppKit

// MARK: - 图片编辑器（旋转 / 镜像 / 翻转 / 裁剪 / 亮度对比度 / 打印预览）

struct ImageEditorSheet: View {
    let source: CGImage
    let title: String
    @ObservedObject var settings: PrintSettings
    let onPrint: (CGImage) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum PreviewTab: String, CaseIterable, Identifiable {
        case edit = "编辑"
        case print = "打印预览"
        var id: String { rawValue }
    }

    @State private var previewTab = PreviewTab.edit
    @State private var rotation = 0          // 顺时针 0/90/180/270
    @State private var flipH = false         // 左右镜像
    @State private var flipV = false         // 上下翻转
    @State private var showCrop = false
    @State private var cx: CGFloat = 0.5
    @State private var cy: CGFloat = 0.5
    @State private var cw: CGFloat = 1.0
    @State private var ch: CGFloat = 1.0
    @State private var aspectIndex = 0       // 0自由 1:1 4:3 3:4 16:9
    @State private var dragStart: (CGFloat, CGFloat)?

    private let aspectOptions: [(String, CGFloat?)] = [
        ("自由", nil), ("1:1", 1.0), ("4:3", 4.0 / 3.0),
        ("3:4", 3.0 / 4.0), ("16:9", 16.0 / 9.0),
    ]

    private var options: PrintEngine.RasterOptions { settings.rasterOptions }

    /// 旋转/镜像后的图（裁剪前）
    private var base: CGImage? {
        PrintEngine.applyOrientation(source, rotationDegrees: rotation, flipH: flipH, flipV: flipV)
    }

    private var cropRect: CGRect {
        CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch)
    }

    /// 最终要打印的图（已应用旋转/镜像/裁剪）
    private var edited: CGImage? {
        guard let base else { return nil }
        guard showCrop else { return base }
        let px = CGRect(x: cropRect.minX * CGFloat(base.width),
                        y: cropRect.minY * CGFloat(base.height),
                        width: cropRect.width * CGFloat(base.width),
                        height: cropRect.height * CGFloat(base.height))
        return PrintEngine.crop(base, to: px) ?? base
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.below.rectangle")
                Text("编辑图片：\(title)").font(.headline).lineLimit(1)
                Spacer()
                Button("重置") { reset() }
                    .controlSize(.small)
            }
            .padding(12)
            Divider()

            HStack(spacing: 0) {
                previewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                controls
                    .frame(width: 300)
            }

            Divider()
            footer
        }
        .frame(width: 900, height: 660)
    }

    // MARK: 预览区

    private var previewArea: some View {
        VStack(spacing: 8) {
            Picker("", selection: $previewTab) {
                ForEach(PreviewTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 10)

            if previewTab == .edit {
                GeometryReader { geo in
                    if let base {
                        let fit = fitSize(base, in: geo.size)
                        let ox = (geo.size.width - fit.width) / 2
                        let oy = (geo.size.height - fit.height) / 2
                        ZStack(alignment: .topLeading) {
                            Image(decorative: base, scale: 1, orientation: .up)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: fit.width, height: fit.height)
                                .position(x: ox + fit.width / 2, y: oy + fit.height / 2)

                            if showCrop {
                                let r = CGRect(x: ox + cropRect.minX * fit.width,
                                               y: oy + cropRect.minY * fit.height,
                                               width: cropRect.width * fit.width,
                                               height: cropRect.height * fit.height)
                                Rectangle()
                                    .fill(Color.black.opacity(0.35))
                                    .frame(width: r.width, height: r.height)
                                    .position(x: r.midX, y: r.midY)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .strokeBorder(Color.accentColor, lineWidth: 2)
                                    )
                                    .gesture(
                                        DragGesture()
                                            .onChanged { g in
                                                if dragStart == nil { dragStart = (cx, cy) }
                                                cx = clampCenter(dragStart!.0 + g.translation.width / fit.width, half: cw / 2)
                                                cy = clampCenter(dragStart!.1 + g.translation.height / fit.height, half: ch / 2)
                                            }
                                            .onEnded { _ in dragStart = nil }
                                    )
                            }
                        }
                    }
                }
                .padding(10)
            } else {
                PrintPreviewPane(source: edited, options: options, toggleable: false)
                    .padding(10)
            }
        }
    }

    // MARK: 控制区

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                group("旋转") {
                    HStack(spacing: 6) {
                        Button { rotation = (rotation + 270) % 360 } label: {
                            Label("左转", systemImage: "rotate.left")
                        }
                        Button { rotation = (rotation + 90) % 360 } label: {
                            Label("右转", systemImage: "rotate.right")
                        }
                        Button("180°") { rotation = (rotation + 180) % 360 }
                    }
                    .controlSize(.small)
                }

                group("镜像 / 翻转") {
                    HStack(spacing: 6) {
                        Button {
                            flipH.toggle()
                        } label: {
                            Label("左右镜像", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        }
                        .tint(flipH ? Color.accentColor : nil)
                        Button {
                            flipV.toggle()
                        } label: {
                            Label("上下翻转", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                        }
                        .tint(flipV ? Color.accentColor : nil)
                    }
                    .controlSize(.small)
                }

                Divider()

                group("裁剪") {
                    Toggle("启用裁剪", isOn: $showCrop)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    Picker("比例", selection: $aspectIndex) {
                        ForEach(Array(aspectOptions.enumerated()), id: \.offset) { idx, item in
                            Text(item.0).tag(idx)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: aspectIndex) { _ in applyAspect() }
                    HStack {
                        Text("宽").font(.caption).frame(width: 22)
                        Slider(value: $cw, in: 0.1...1.0)
                    }
                    .disabled(!showCrop)
                    HStack {
                        Text("高").font(.caption).frame(width: 22)
                        Slider(value: $ch, in: 0.1...1.0)
                    }
                    .disabled(!showCrop)
                }

                Divider()

                group("打印效果") {
                    HStack {
                        Text("亮度").font(.caption).frame(width: 32)
                        Slider(value: $settings.brightness, in: -0.6...0.6)
                    }
                    HStack {
                        Text("对比度").font(.caption).frame(width: 32)
                        Slider(value: $settings.contrast, in: -0.6...0.6)
                    }
                    Toggle("抖动（照片更细腻）", isOn: $settings.dithering)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }
            }
            .padding(12)
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let edited {
                    let rows = max(1, Int((CGFloat(edited.height) * (PrintEngine.printWidthMM
                                / (PrintEngine.dotPitchMM * CGFloat(edited.width))) * PrintEngine.verticalCorrection).rounded()))
                    Text("预计打印尺寸：\(String(format: "%.1f", PrintEngine.printWidthMM)) × \(String(format: "%.1f", CGFloat(rows) * PrintEngine.rowPitchMM)) mm")
                        .font(.caption)
                    Text("\(edited.width) × \(edited.height) px → 点阵 \(PrintEngine.paperDots) × \(rows) 行")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("取消") { dismiss() }
            Button("打印") {
                if let edited { onPrint(edited) }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func reset() {
        rotation = 0
        flipH = false
        flipV = false
        showCrop = false
        cx = 0.5; cy = 0.5; cw = 1.0; ch = 1.0
        aspectIndex = 0
        settings.brightness = 0
        settings.contrast = 0
        settings.dithering = true
    }

    private func applyAspect() {
        guard let ratio = aspectOptions[aspectIndex].1, let img = base else {
            cw = 1.0; ch = 1.0; cx = 0.5; cy = 0.5
            return
        }
        let W = CGFloat(img.width), H = CGFloat(img.height)
        var w: CGFloat = 0.95
        var h = (w * W / ratio) / H
        if h > 0.95 { h = 0.95; w = (h * H * ratio) / W }
        cw = min(max(w, 0.1), 1.0)
        ch = min(max(h, 0.1), 1.0)
        cx = 0.5; cy = 0.5
    }

    private func fitSize(_ img: CGImage, in size: CGSize) -> CGSize {
        let s = min(size.width / CGFloat(img.width), size.height / CGFloat(img.height))
        return CGSize(width: CGFloat(img.width) * s, height: CGFloat(img.height) * s)
    }

    private func clampCenter(_ v: CGFloat, half: CGFloat) -> CGFloat {
        min(max(v, half), 1 - half)
    }
}

