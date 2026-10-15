import Darwin
import DigUpKit
import Foundation

/// Deterministic, model-free profiling of the real SQLite/vector search path. Temporary indexes are removed on exit.
@main enum SearchBenchmark {
    struct Options {
        var sizes = [10_000, 50_000, 100_000]
        var iterations = 15
        var directory = FileManager.default.temporaryDirectory
        var output: URL?

        init() throws {
            let args = Array(CommandLine.arguments.dropFirst())
            var index = 0
            while index < args.count {
                if args[index] == "--help" {
                    print("digup-benchmark [--sizes 10000,50000,100000] [--iterations 15] [--directory DIR] [--output report.json]")
                    exit(0)
                }
                guard index + 1 < args.count else { throw Failure("Missing value for \(args[index])") }
                let value = args[index + 1]
                switch args[index] {
                case "--sizes":
                    let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                    let sizes = parts.compactMap { Int($0) }
                    guard !sizes.isEmpty, sizes.count == parts.count,
                          sizes.allSatisfy({ (100...1_000_000).contains($0) }) else { throw Failure("Sizes must be 100...1000000") }
                    self.sizes = sizes
                case "--iterations":
                    guard let count = Int(value), (1...200).contains(count) else { throw Failure("Iterations must be 1...200") }
                    iterations = count
                case "--directory": directory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                case "--output": output = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                default: throw Failure("Unknown option: \(args[index])")
                }
                index += 2
            }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    struct Sample {
        let milliseconds: Double
        let statements: Int
        let scans: Int
        let phases: SearchMetrics
    }

    struct Summary: Encodable {
        let iterations: Int
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let minMilliseconds: Double
        let maxMilliseconds: Double
        let meanStatements: Double
        let meanVectorScans: Double
        let meanVectorMilliseconds: Double
        let meanKeywordMilliseconds: Double
        let meanRankingMilliseconds: Double
        let meanHydrationMilliseconds: Double

        init(_ samples: [Sample]) {
            iterations = samples.count
            let times = samples.map(\.milliseconds).sorted()
            p50Milliseconds = times[max(0, Int(ceil(Double(times.count) * 0.5)) - 1)]
            p95Milliseconds = times[max(0, Int(ceil(Double(times.count) * 0.95)) - 1)]
            minMilliseconds = times.first ?? 0
            maxMilliseconds = times.last ?? 0
            let count = Double(samples.count)
            meanStatements = Double(samples.map(\.statements).reduce(0, +)) / count
            meanVectorScans = Double(samples.map(\.scans).reduce(0, +)) / count
            meanVectorMilliseconds = samples.map { $0.phases.vectorMilliseconds }.reduce(0, +) / count
            meanKeywordMilliseconds = samples.map { $0.phases.keywordMilliseconds }.reduce(0, +) / count
            meanRankingMilliseconds = samples.map { $0.phases.rankingMilliseconds }.reduce(0, +) / count
            meanHydrationMilliseconds = samples.map { $0.phases.hydrationMilliseconds }.reduce(0, +) / count
        }
    }

    struct Dataset: Encodable {
        let files: Int
        let vectors: Int
        let databaseBytes: Int64
        let vectorBytes: Int
        let setupMilliseconds: Double
        let loadMilliseconds: Double
        let firstSearch: Summary
        let distinctQueries: Summary
        let sixFilterCycle: Summary
        let repeatedFilterCycle: Summary
        let keywordPage: Summary
        let processPeakResidentMiB: Double
    }

    struct Report: Encodable {
        let generatedAt = Date()
        let revision = ProcessInfo.processInfo.environment["DIGUP_BENCHMARK_REVISION"] ?? "working-tree"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let architecture = "arm64"
        let processors = ProcessInfo.processInfo.activeProcessorCount
        let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        let workload = "Deterministic synthetic index; precomputed query vectors; excludes model encoding, UI and filesystem existence checks"
        let datasets: [Dataset]
    }

    static let filters: [Set<FileKind>?] = [nil, [.screenshot], [.image], [.pdf, .doc], [.audio], [.video]]

    static func main() {
        do {
            let options = try Options()
            var results: [Dataset] = []
            for size in options.sizes { results.append(try profile(size, options: options)) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Report(datasets: results))
            if let output = options.output { try data.write(to: output, options: .atomic) }
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("benchmark: \(error)\n".utf8))
            exit(1)
        }
    }

    static func profile(_ count: Int, options: Options) throws -> Dataset {
        let folder = options.directory.appendingPathComponent("DigUp-benchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        FileHandle.standardError.write(Data("Profiling \(count) files/vectors…\n".utf8))
        let store = try IndexStore(directory: folder)
        let setup = now()
        try populate(store, count: count)
        try store.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let setupMS = elapsed(setup)
        let load = now()
        let searcher = try Searcher(store: store)
        let loadMS = elapsed(load)
        var vector = [Float](repeating: 0, count: 768)
        vector[0] = 1

        func measure(_ text: String, filters: [Set<FileKind>?], vector: [Float]?) throws -> Sample {
            let started = now(), statements = store.db.preparedStatementCount, scans = searcher.vectorScanCount
            var phases = SearchMetrics()
            for kinds in filters {
                let page = try searcher.searchPage(text, queryVector: vector, kinds: kinds, limit: 120)
                guard page.all.count <= 120, page.hits.count <= 120 else { throw Failure("Result limit exceeded") }
                phases.vectorMilliseconds += searcher.lastMetrics.vectorMilliseconds
                phases.keywordMilliseconds += searcher.lastMetrics.keywordMilliseconds
                phases.rankingMilliseconds += searcher.lastMetrics.rankingMilliseconds
                phases.hydrationMilliseconds += searcher.lastMetrics.hydrationMilliseconds
            }
            return Sample(milliseconds: elapsed(started), statements: store.db.preparedStatementCount - statements,
                          scans: searcher.vectorScanCount - scans, phases: phases)
        }

        let first = try measure("budget quarterly first", filters: [[.pdf, .doc]], vector: vector)
        var distinct: [Sample] = [], cycles: [Sample] = [], repeated: [Sample] = [], words: [Sample] = []
        for iteration in 0..<options.iterations {
            distinct.append(try measure("budget quarterly distinct\(iteration)", filters: [[.pdf, .doc]], vector: vector))
        }
        for iteration in 0..<options.iterations {
            cycles.append(try measure("budget quarterly cycle\(iteration)", filters: filters, vector: vector))
        }
        for _ in 0..<options.iterations {
            repeated.append(try measure("budget quarterly cycle\(options.iterations - 1)", filters: filters, vector: vector))
        }
        searcher.releaseVectors()
        for iteration in 0..<options.iterations {
            words.append(try measure("budget quarterly keyword\(iteration)", filters: [[.pdf, .doc]], vector: nil))
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Dataset(files: count, vectors: count, databaseBytes: IndexStore.size(of: store.file),
                       vectorBytes: count * 768 * 2, setupMilliseconds: setupMS, loadMilliseconds: loadMS,
                       firstSearch: Summary([first]), distinctQueries: Summary(distinct), sixFilterCycle: Summary(cycles),
                       repeatedFilterCycle: Summary(repeated), keywordPage: Summary(words),
                       processPeakResidentMiB: Double(usage.ru_maxrss) / 1_048_576)
    }

    static func populate(_ store: IndexStore, count: Int) throws {
        var seed: UInt64 = 0xD16_0001
        func random() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
        }
        var template = (0..<768).map { _ in random() }
        template[0] = 0
        let norm = sqrt(template.reduce(Float(0)) { $0 + $1 * $1 })
        template = template.map { $0 / norm }
        let kinds: [FileKind] = [.screenshot, .image, .pdf, .doc, .audio, .video]
        for start in stride(from: 0, to: count, by: 1000) {
            try store.db.transaction {
                for number in start..<min(start + 1000, count) {
                    let id = Int64(number + 1), kind = kinds[number % kinds.count]
                    let strong = number % 97 == 0
                    let first: Float = strong ? 0.6 : random() * 0.08
                    let scale = sqrt(1 - first * first)
                    var vector = template.map { $0 * scale }
                    vector[0] = first
                    let text = number % 5 == 0 ? "Quarterly budget receipts for the garden project."
                        : "Meeting notes about train timetables and the library."
                    let segment: SegmentKind
                    let modality: Modality
                    let loc: Double?
                    switch kind {
                    case .screenshot, .image: (segment, modality, loc) = (.image, .image, nil)
                    case .pdf: (segment, modality, loc) = (.page, .text, 3)
                    case .doc, .code: (segment, modality, loc) = (.chunk, .text, 1)
                    case .audio: (segment, modality, loc) = (.audio, .audio, 25)
                    case .video: (segment, modality, loc) = (.frame, .image, 6)
                    }
                    try store.db.run("""
                        INSERT INTO files(id, path, kind, size, mtime, inode, device, state, info)
                        VALUES(?, ?, ?, ?, ?, ?, 1, 'done', ?)
                        """, [.int(id), .text(String(format: "/synthetic/entry-%06d", number)), .text(kind.rawValue),
                              .int(4096), .double(Double(number)), .int(id), .text("{\"pages\":\"16\",\"duration\":\"120\"}")])
                    try store.addSegment(file: id, kind: segment, modality: modality, loc: loc, text: text, vector: vector)
                }
            }
        }
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func elapsed(_ start: UInt64) -> Double { Double(now() - start) / 1_000_000 }
}
