//
//  PrintHistory.swift
//  B3 热敏打印 App —— 打印历史（含持久化）
//
//  数据存 Application Support/ThermalPrinter/History/：点阵存 .bin，索引存 index.json，
//  只保留最近 maxRecords 条。重打时直接用保存的打印序列。
//

import Foundation

@MainActor
final class PrintHistory: ObservableObject {
    /// 内存中保留的上限；落盘同样只保留这么多条
    private static let maxRecords = 30

    @Published private(set) var records: [PrintRecord] = []

    init() {
        records = Self.load()
    }

    /// 加入一条并落盘（最新的在最前）
    func add(_ record: PrintRecord) {
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records.removeLast(records.count - Self.maxRecords)
        }
        persist()
    }

    func clear() {
        records.removeAll()
        persist()
    }

    // MARK: - 持久化

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let d = base.appendingPathComponent("ThermalPrinter", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static var indexURL: URL { dir.appendingPathComponent("index.json") }

    private struct Item: Codable {
        let id: UUID
        let time: Date
        let kind: String
        let title: String
        let height: Int
        let file: String
    }

    private static func load() -> [PrintRecord] {
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items.compactMap { item in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(item.file)) else { return nil }
            return PrintRecord(id: item.id, time: item.time, kind: item.kind,
                               title: item.title, data: d, height: item.height)
        }
    }

    private func persist() {
        let kept = Array(records.prefix(Self.maxRecords))
        let keepIds = Set(kept.map { $0.id })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.dir.path)) ?? []
        for f in files where f.hasSuffix(".bin") {
            let idStr = String(f.dropLast(4))
            if let id = UUID(uuidString: idStr), !keepIds.contains(id) {
                try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(f))
            }
        }
        for rec in kept {
            try? rec.data.write(to: Self.dir.appendingPathComponent("\(rec.id.uuidString).bin"))
        }
        let items = kept.map { Item(id: $0.id, time: $0.time, kind: $0.kind,
                                    title: $0.title, height: $0.height,
                                    file: "\($0.id.uuidString).bin") }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: Self.indexURL)
        }
    }
}
