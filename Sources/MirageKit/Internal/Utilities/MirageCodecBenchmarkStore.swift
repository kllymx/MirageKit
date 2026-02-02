//
//  MirageCodecBenchmarkStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Local storage for codec benchmark results.
//

import Foundation

struct MirageCodecBenchmarkStore {
    struct Record: Codable, Equatable {
        let version: Int
        let benchmarkWidth: Int
        let benchmarkHeight: Int
        let benchmarkFrameRate: Int
        let hostEncodeMs: Double?
        let clientDecodeMs: Double?
        let measuredAt: Date
    }

    static let currentVersion = 1

    private let fileURL: URL

    init(filename: String = "MirageCodecBenchmark.json") {
        fileURL = URL.cachesDirectory.appending(path: filename)
    }

    func load() -> Record? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    func save(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = fileURL
            try? mutableURL.setResourceValues(values)
        } catch {
            return
        }
    }
}
