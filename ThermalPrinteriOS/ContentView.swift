//
//  ContentView.swift
//  B3 热敏打印 App 界面
//

import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var printer = PrinterController()
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                deviceListSection
                if printer.isConnected {
                    printSection
                }
                logSection
            }
            .navigationTitle("热敏打印")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(printer.isConnected ? "断开" : "扫描") {
                        if printer.isConnected {
                            printer.disconnect()
                        } else {
                            printer.scan()
                        }
                    }
                    .disabled(printer.isPrinting)
                }
            }
            .onAppear {
                if !printer.isConnected && !printer.isScanning {
                    printer.scan()
                }
            }
            .onChange(of: selectedPhoto) { newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        printer.printImage(image)
                    } else {
                        printer.log("无法读取所选图片")
                    }
                }
                selectedPhoto = nil
            }
        }
    }

    // MARK: - 设备列表

    private var deviceListSection: some View {
        Group {
            if printer.discovered.isEmpty {
                HStack {
                    if printer.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Text(printer.isScanning ? "正在搜索热敏打印机…" : "点右上角「扫描」查找打印机")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            } else {
                List {
                    ForEach(printer.discovered, id: \.identifier) { p in
                        Button {
                            printer.connect(p)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(p.name ?? "未命名")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(p.identifier.uuidString)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if printer.connectedName == p.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .frame(height: 220)
            }
        }
    }

    // MARK: - 打印区

    private var printSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "printer.fill").foregroundStyle(.green)
                Text("已连接：\(printer.connectedName ?? "")")
                    .font(.subheadline)
                Spacer()
                if printer.isPrinting {
                    ProgressView().controlSize(.small)
                    Text("打印中…").font(.footnote).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    printer.printQR(text: "BUDING-B3 PRINT OK")
                } label: {
                    Label("打印测试二维码", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(printer.isPrinting)

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("从相册选图打印", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(printer.isPrinting)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - 日志

    private var logSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(printer.logText)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
                    .id("logBottom")
                    .onChange(of: printer.logText) { _ in
                        withAnimation { proxy.scrollTo("logBottom", anchor: .bottom) }
                    }
            }
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding([.horizontal, .bottom])
        .frame(maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
