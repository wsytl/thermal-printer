//
//  ContentView.swift  (macOS)
//  B3 热敏打印 App —— 主界面
//
//  职责（只做协调，不放业务）：
//   - 顶部状态栏：连接状态 / 打印进度 / 队列
//   - 三种打印模式切换：文本 / 二维码 / 图片（各自独立视图）
//   - 日志区（可折叠）
//   - 底部：打印历史、显示日志、打印浓度、断开/扫描
//
//  状态归属：
//   - PrintSettings     打印设置（亮度/对比度/抖动/浓度 + 文本排版）
//   - PrintHistory      打印历史（含持久化）
//   - PrinterController BLE 连接与打印队列
//   - 各模式视图自己持有输入内容（文本 / 二维码 / 图片列表）
//

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var printer = PrinterController()
    @StateObject private var settings = PrintSettings()
    @StateObject private var history = PrintHistory()

    @State private var selectedTab = TabKind.text
    @State private var pending: PendingImage?
    @State private var showHistory = false
    @State private var showLog = true
    @State private var autoConnectTask: Task<Void, Never>?

    enum TabKind: String, CaseIterable, Identifiable {
        case text = "文本"
        case qr = "二维码"
        case image = "图片"
        var id: String { rawValue }
    }

    private var canPrint: Bool { printer.isConnected && !printer.isPrinting }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            tabPicker
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showLog {
                Divider()
                logSection.frame(height: 110)
            }
            Divider()
            footerBar
                .sheet(isPresented: $showHistory) { historySheet }
        }
        .frame(minWidth: 820, minHeight: 660)
        .navigationTitle("热敏打印")
        .sheet(item: $pending) { p in
            ImageEditorSheet(source: p.image, title: p.title, settings: settings) { edited in
                printImage(edited, title: p.title)
            }
        }
        .onAppear {
            if !printer.isConnected && !printer.isScanning {
                printer.scan()
            }
        }
        .onChange(of: printer.discovered.count) { _ in
            autoConnectIfNeeded()
        }
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: printer.isConnected ? "printer.fill" : "printer")
                .foregroundStyle(printer.isConnected ? Color.green : Color.secondary)
            Text(printer.isConnected ? (printer.connectedName ?? "已连接") : "未连接")
                .font(.subheadline)
            if printer.isScanning {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if printer.isPrinting {
                printProgress
            } else if !printer.isConnected {
                Button("扫描") { printer.scan() }.controlSize(.small)
            } else {
                Text("就绪").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var printProgress: some View {
        if let p = printer.sendingProgress {
            ProgressView(value: p).frame(width: 140)
            Text("发送 \(Int(p * 100))%").font(.caption).monospacedDigit()
        } else {
            ProgressView().controlSize(.small)
            Text("打印中…").font(.caption)
        }
        if let job = printer.currentJobLabel {
            Text(job).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        if printer.queueCount > 0 {
            Text("队列 \(printer.queueCount)").font(.caption).foregroundStyle(.orange)
        }
        Button("取消队列") { printer.cancelQueue() }
            .controlSize(.small)
            .disabled(printer.queueCount == 0)
    }

    // MARK: - 模式切换与内容

    private var tabPicker: some View {
        Picker("打印模式", selection: $selectedTab) {
            ForEach(TabKind.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .text:
            TextPrintView(settings: settings, canPrint: canPrint, enqueue: enqueue)
        case .qr:
            QRPrintView(settings: settings, canPrint: canPrint, enqueue: enqueue)
        case .image:
            ImagePrintView(settings: settings, canPrint: canPrint,
                           enqueue: enqueue, onEdit: { pending = $0 })
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(printer.logText)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .textSelection(.enabled)
                    .id("logBottom")
                    .onChange(of: printer.logText) { _ in
                        withAnimation { proxy.scrollTo("logBottom", anchor: .bottom) }
                    }
            }
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 底部栏

    private var footerBar: some View {
        HStack {
            Button { showHistory = true } label: {
                Label("打印历史（\(history.records.count)）", systemImage: "clock.arrow.circlepath")
            }
            .controlSize(.small)

            Button {
                withAnimation { showLog.toggle() }
            } label: {
                Label(showLog ? "隐藏日志" : "显示日志", systemImage: "terminal")
            }
            .controlSize(.small)

            Divider().frame(height: 16)

            Text("浓度 中（\(PrintSettings.fixedDensity)）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("打印深浅固定为中等（3/5）。如需调节改 PrintSettings.fixedDensity")

            Spacer()

            Button(printer.isConnected ? "断开" : "扫描") {
                if printer.isConnected {
                    printer.disconnect()
                } else {
                    printer.scan()
                }
            }
            .controlSize(.small)
            .disabled(printer.isPrinting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 历史面板

    private var historySheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("打印历史").font(.headline)
                Spacer()
                Button("清空") { history.clear() }.controlSize(.small)
                Button("完成") { showHistory = false }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding()
            Divider()
            if history.records.isEmpty {
                Spacer()
                Text("暂无打印记录").foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(history.records) { rec in
                        historyRow(rec)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 500, height: 430)
    }

    private func historyRow(_ rec: PrintRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: rec.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.title).font(.subheadline).lineLimit(1)
                Text("\(rec.kind) · \(rec.height) 行 · \(rec.time.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新打印") {
                printer.enqueue(data: rec.data, label: "\(rec.kind)：\(rec.title)")
            }
            .controlSize(.small)
            .disabled(!canPrint)
        }
    }

    // MARK: - 动作

    /// 各模式视图构建好打印序列后交给这里：记历史 + 入队
    private func enqueue(_ data: Data, _ kind: String, _ title: String, _ height: Int) {
        history.add(PrintRecord(id: UUID(), time: Date(), kind: kind,
                                title: title, data: data, height: height))
        printer.enqueue(data: data, label: "\(kind)：\(title)")
    }

    private func printImage(_ image: CGImage, title: String) {
        guard let job = PrintEngine.makePrintData(from: image, options: settings.rasterOptions) else { return }
        enqueue(job.data, "图片", title, job.height)
    }

    private func autoConnectIfNeeded() {
        guard !printer.isConnected, let first = printer.discovered.first else { return }
        // 去抖 500ms：等待所有发现回调聚齐，避免连到中间出现的设备
        autoConnectTask?.cancel()
        autoConnectTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !printer.isConnected,
                  printer.discovered.first?.identifier == first.identifier else { return }
            printer.connect(first)
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "文本": return "text.alignleft"
        case "二维码": return "qrcode"
        default: return "photo"
        }
    }
}

#Preview {
    ContentView()
}
