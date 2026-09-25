//
//  ImagePrintView.swift
//  B3 热敏打印 App —— 图片打印模式（可多选、批量打印、点选预览）
//
//  亮度/对比度/抖动为三模式共用的打印设置；裁剪与旋转镜像在图片编辑器里做。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImagePrintView: View {
    @ObservedObject var settings: PrintSettings
    let canPrint: Bool
    let enqueue: (Data, String, String, Int) -> Void
    /// 打开图片编辑器（上层用 sheet 呈现）
    let onEdit: (PendingImage) -> Void

    @State private var images: [PickedImage] = []
    @State private var selectedID: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button { pickImages() } label: {
                        Label("选择图片（可多选）", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button { printAll() } label: {
                        Label("打印全部（\(images.count)张）", systemImage: "printer.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPrint || images.isEmpty)
                }

                HStack(spacing: 12) {
                    Text("亮度").font(.caption)
                    Slider(value: $settings.brightness, in: -0.6...0.6).frame(width: 110)
                    Text("对比度").font(.caption)
                    Slider(value: $settings.contrast, in: -0.6...0.6).frame(width: 110)
                    Toggle("抖动", isOn: $settings.dithering)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    Spacer()
                }

                Text("点缩略图选中并预览；点「编辑」可裁剪 / 旋转 / 镜像")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if images.isEmpty {
                    emptyHint
                } else {
                    thumbnailGrid
                }
            }
            .padding(12)

            Divider()

            PrintPreviewPane(source: selectedImage, options: settings.rasterOptions)
                .frame(width: 250)
                .padding(12)
        }
    }

    // MARK: - 子视图

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "photo")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("还没有图片").font(.headline).foregroundStyle(.secondary)
            Text("点上方「选择图片」挑选要打印的照片")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var thumbnailGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(images) { item in
                    VStack(spacing: 4) {
                        Image(decorative: item.image, scale: 1, orientation: .up)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 100)
                            .frame(maxWidth: .infinity)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(selectedID == item.id ? Color.accentColor : .clear,
                                                  lineWidth: 3)
                            )
                            .onTapGesture { selectedID = item.id }
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("编辑") {
                                onEdit(PendingImage(image: item.image, title: item.title))
                            }
                            .controlSize(.mini)
                            .disabled(!canPrint)
                            Button {
                                images.removeAll { $0.id == item.id }
                                if selectedID == item.id { selectedID = nil }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .controlSize(.mini)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - 私有

    private var selectedImage: CGImage? {
        if let id = selectedID, let hit = images.first(where: { $0.id == id }) {
            return hit.image
        }
        return images.first?.image
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "选择要打印的图片（自动应用 EXIF 方向；点缩略图下方「编辑」可裁剪）"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let image = PrintEngine.loadImageOriented(from: url) {
                images.append(PickedImage(image: image, title: url.lastPathComponent))
            }
        }
    }

    private func printAll() {
        for item in images {
            guard let job = PrintEngine.makePrintData(from: item.image,
                                                      options: settings.rasterOptions) else { continue }
            enqueue(job.data, "图片", item.title, job.height)
        }
    }
}
