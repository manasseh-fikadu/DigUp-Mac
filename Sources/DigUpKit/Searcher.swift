import Foundation

public struct SearchHit: Sendable {
    public let path: String
    public let kind: FileKind
    public let score: Double          // fused rank score, for ordering only
    public let z: Double?             // how far the best segment stands out for this query (`Searcher.meaning`)
    public let cosine: Double?
    public let keywordRank: Int?      // 1-based rank among keyword matches
    public let segment: SegmentKind
    /// The segment the hit points at (its text is `Searcher.text(ofSegment:)`).
    public let segmentID: Int64
    public let loc: Double?           // PDF page, or seconds into audio/video
    public let locEnd: Double?
    public let excerpt: String?
    /// The file's modification date (seconds since 1970), and what indexing learned about it: "width", "height",
    /// "taken", "pages", "duration"… (see `Indexer`).
    public let modified: Double
    public let size: Int64
    public let info: [String: String]
    /// Code: the line to open at, in the stretch (`loc`…`locEnd`): where the name looked up is defined, or the first
    /// line with the query's words. Nil: the stretch's first line.
    public var focus: Double? = nil
}

/// One window update: counts come from `all`, while `hits` has a full page of the selected kinds.
public struct SearchPage: Sendable {
    public let all: [SearchHit]
    public let hits: [SearchHit]

    public init(all: [SearchHit], hits: [SearchHit]) {
        self.all = all
        self.hits = hits
    }
}

/// Timings and actual work for the most recent search, excluding model encoding and file-system checks.
public struct SearchMetrics: Codable, Sendable {
    public var reusedQuery = false
    public var vectorScans = 0
    public var sqlStatements = 0
    public var vectorMilliseconds = 0.0
    public var keywordMilliseconds = 0.0
    public var rankingMilliseconds = 0.0
    public var hydrationMilliseconds = 0.0
    public var hydratedRows = 0

    public init() {}
}

/// Hybrid search: meaning (EmbeddingGemma's vectors) + words (FTS5).
///
/// Meaning is the model's cosine similarity, put on one scale per query (`meaning`): every vector is scored anyway, so
/// the distribution comes for free, and only segments that stand out (`zGate`) count as meaning matches. That also
/// gives an honest "nothing found". Words rescue what a vector can't hold exactly: codes, IDs and names.
public final class Searcher {
    let store: IndexStore
    public private(set) var lastMetrics = SearchMetrics()
    public private(set) var vectorScanCount = 0
    private var loadedRevision: Database.Revision?
    private var prepared: PreparedQuery?

    private struct MeaningMatch {
        let z: Double
        let cosine: Double
        let segment: Int64
    }

    private struct WordMatch {
        let file: Int64
        let segment: Int64
        let kind: SegmentKind
    }

    /// One query only. Changing kind/limit reuses its scan; index writes, reload and idle release discard it.
    private final class PreparedQuery {
        let text: String
        let vector: [Float]?
        let prefixLast: Bool
        let terms: [String]
        let identifier: [String]?
        let patterns: [String]
        let meaning: [Int64: MeaningMatch]
        let words: [WordMatch]
        var coverage: [Int64: Double] = [:]
        var coveredFiles = Set<Int64>()
        var snippets: [Int64: String] = [:]
        var snippetsLoaded = Set<Int64>()
        var records: [Int64: HitRecord] = [:]   // at most 1,024 hydrated segments
        var selections: [SelectionKey: [Selection]] = [:]   // at most 16 pages, each at most 256 results

        init(text: String, vector: [Float]?, prefixLast: Bool, terms: [String], identifier: [String]?,
             patterns: [String], meaning: [Int64: MeaningMatch], words: [WordMatch]) {
            self.text = text
            self.vector = vector
            self.prefixLast = prefixLast
            self.terms = terms
            self.identifier = identifier
            self.patterns = patterns
            self.meaning = meaning
            self.words = words
        }
    }

    private struct Selection {
        let file: Int64
        let score: Double
        let semantic: MeaningMatch?
        let keyword: (rank: Int, match: WordMatch)?
        var segment: Int64
        var focus: Double?
        var focusWords: [String]?
    }

    private struct SelectionKey: Hashable {
        let kinds: Set<FileKind>?
        let limit: Int
        let zGate: Double
        let wordWeight: Double
    }

    private struct HitRecord {
        let segment: SegmentKind
        let loc: Double?
        let locEnd: Double?
        let excerpt: String?
        let path: String
        let kind: FileKind
        let modified: Double
        let size: Int64
        let info: [String: String]
        let text: String?
    }
    private var matrix: VectorStorage?   // rows × 768 float16, row-major
    private var rowFile: [Int64] = []
    private var rowSegment: [Int64] = []
    private var rowModality: [Modality] = []
    /// False for the vectors the later pass adds (`Indexer.finishLongFiles`): scored, but they don't set the scale.
    private var rowSetsScale: [Bool] = []
    private var fileKind: [Int64: FileKind] = [:]
    public private(set) var vectorSource: String?
    /// False after `releaseVectors()` (or `loadVectors: false`): keyword search still works, and the next search with
    /// a query vector loads them again.
    public private(set) var vectorsLoaded = false

    public var vectorCount: Int { rowFile.count }

    /// This is the code index's searcher (`IndexStore.codeFile`): names are looked up as names (`CodeLookup`).
    public var isCode: Bool { store.file.lastPathComponent == IndexStore.codeFile }

    /// With `loadVectors: false` only keyword search is ready; vectors load on the first meaning search. The app
    /// uses that to stay small while idle: 20k vectors are ~30 MB.
    public init(store: IndexStore, loadVectors: Bool = true) throws {
        self.store = store
        if loadVectors { try reload() } else { try reloadFiles() }
    }

    /// Reads the files and all vectors again (after indexing added some).
    public func reload() throws {
        releaseVectors()
        try reloadFiles()
        var rows = 0
        try store.db.query("SELECT COUNT(*) FROM segments WHERE vec IS NOT NULL") { rows = Int($0.int(0)) }
        guard let matrix = VectorStorage(rows: rows) else {
            vectorsLoaded = true   // nothing to load
            return
        }
        let rowBytes = Vectors.dimension * MemoryLayout<Float16>.stride
        let steps = IndexOptions()
        try store.db.query("""
            SELECT s.id, s.file, s.modality, s.vec, s.kind, s.loc, f.kind, CAST(json_extract(f.info, '$.pages') AS INTEGER)
            FROM segments s JOIN files f ON f.id = s.file WHERE s.vec IS NOT NULL ORDER BY s.id
            """) { row in
            guard let blob = row.blob(3), blob.count == rowBytes, rowFile.count < rows else { return }
            blob.copyBytes(to: UnsafeMutableRawBufferPointer(start: matrix.halves + rowFile.count * Vectors.dimension,
                                                             count: rowBytes))
            rowSegment.append(row.int(0))
            rowFile.append(row.int(1))
            rowModality.append(Modality(rawValue: row.text(2) ?? "") ?? .none)
            // Past the first step of a long PDF (its pages) or document (its chunks).
            let (kind, place) = (row.text(4), row.isNull(5) ? 0 : Int(row.double(5)))
            let later = row.text(6) == "pdf"
                ? kind != SegmentKind.chunk.rawValue && Int(row.int(7)) > steps.bigPDFPages && place > steps.pdfStep
                : kind == SegmentKind.chunk.rawValue && place > steps.docStep
            rowSetsScale.append(!later)
        }
        self.matrix = matrix
        vectorsLoaded = true
    }

    /// Frees the vectors' memory; keyword search keeps working.
    public func releaseVectors() {
        prepared = nil
        matrix = nil
        rowFile = []
        rowSegment = []
        rowModality = []
        rowSetsScale = []
        vectorsLoaded = false
    }

    private func reloadFiles() throws {
        let revision = try store.db.revision()
        fileKind.removeAll(keepingCapacity: true)
        try store.db.query("SELECT id, kind FROM files") { row in
            fileKind[row.int(0)] = FileKind(rawValue: row.text(1) ?? "")
        }
        vectorSource = try store.meta("vector_source")
        loadedRevision = revision
    }

    /// How much finding the query's words counts against meaning (`search`). Code's words count for less: they're
    /// everywhere in code ("app", "running", "location"), and a stretch that shares a few of them beat the one that
    /// does what the query says (2026-10-09, the real-code eval of 27 queries over DigUp, Sparkle and llama.cpp: 18 → 20
    /// found first, the top 5 unchanged; the synthetic code eval 40 → 41 of 41; 1.5 changed nothing, 0.5 lost the top 5).
    public static let wordWeight = 2.0
    public static let codeWordWeight = 1.0

    /// Refresh cached file facts and vectors when either this connection or the indexing helper wrote the index.
    public func refreshIfNeeded() throws {
        guard try store.db.revision() != loadedRevision else { return }
        prepared = nil
        if vectorsLoaded { try reload() } else { try reloadFiles() }
    }

    public func search(_ text: String, queryVector: [Float]?, kinds: Set<FileKind>? = nil, limit: Int = 20,
                       zGate: Double = 2.0, wordWeight: Double? = nil, prefixLast: Bool = false) throws -> [SearchHit] {
        try searches(text, queryVector: queryVector, filters: [kinds], limit: limit, zGate: zGate,
                     wordWeight: wordWeight, prefixLast: prefixLast)[0]
    }

    /// All-kind counts and a complete filtered page share one vector/FTS scan and one hydration batch.
    public func searchPage(_ text: String, queryVector: [Float]?, kinds: Set<FileKind>? = nil, limit: Int = 120,
                           zGate: Double = 2.0, wordWeight: Double? = nil,
                           prefixLast: Bool = false) throws -> SearchPage {
        let results = try searches(text, queryVector: queryVector, filters: kinds == nil ? [nil] : [nil, kinds],
                                   limit: limit, zGate: zGate, wordWeight: wordWeight, prefixLast: prefixLast)
        return SearchPage(all: results[0], hits: results.last!)
    }

    private func searches(_ text: String, queryVector: [Float]?, filters: [Set<FileKind>?], limit: Int,
                          zGate: Double, wordWeight: Double?, prefixLast: Bool) throws -> [[SearchHit]] {
        lastMetrics = SearchMetrics()
        let statements = store.db.preparedStatementCount
        defer { lastMetrics.sqlStatements = store.db.preparedStatementCount - statements }
        guard limit > 0 else { return filters.map { _ in [] } }
        let query = try prepare(text, vector: queryVector, prefixLast: prefixLast)
        let started = DispatchTime.now().uptimeNanoseconds
        let selections = try filters.map { try select(query, kinds: $0, limit: limit, zGate: zGate,
                                                      wordWeight: wordWeight ?? (isCode ? Self.codeWordWeight : Self.wordWeight)) }
        lastMetrics.rankingMilliseconds = Self.elapsed(started)
        let hydration = DispatchTime.now().uptimeNanoseconds
        let records = try records(for: selections.flatMap { $0.map(\.segment) }, query: query)
        let results = selections.map { selected in
            selected.compactMap { selection -> SearchHit? in
                guard let record = records[selection.segment] else { return nil }
                var focus = selection.focus
                if focus == nil, let words = selection.focusWords, let text = record.text {
                    focus = CodeLookup.firstLine(with: words, in: text, first: Int(record.loc ?? 1)).map(Double.init)
                }
                let keyword = selection.keyword
                var snippet = keyword.flatMap {
                    $0.match.segment == selection.segment ? query.snippets[$0.match.segment] : nil
                }.flatMap { $0.contains("«") ? excerpt($0, limit: 400) : nil }
                // An image vector can borrow its own screenshot's OCR, but never another PDF page's text.
                if snippet == nil, record.excerpt == nil, record.loc == nil, let match = keyword?.match,
                   match.kind != .name, let text = query.snippets[match.segment], text.contains("«") {
                    snippet = excerpt(text, limit: 400)
                }
                return SearchHit(path: record.path, kind: record.kind, score: selection.score,
                                 z: selection.semantic?.z, cosine: selection.semantic?.cosine,
                                 keywordRank: keyword?.rank, segment: record.segment, segmentID: selection.segment,
                                 loc: record.loc, locEnd: record.locEnd, excerpt: snippet ?? record.excerpt,
                                 modified: record.modified, size: record.size, info: record.info, focus: focus)
            }
        }
        lastMetrics.hydrationMilliseconds = Self.elapsed(hydration)
        return results
    }

    private func prepare(_ text: String, vector: [Float]?, prefixLast: Bool) throws -> PreparedQuery {
        try refreshIfNeeded()
        if vector != nil, !vectorsLoaded { try reload() }
        if let prepared, prepared.text == text, prepared.vector == vector, prepared.prefixLast == prefixLast {
            lastMetrics.reusedQuery = true
            return prepared
        }
        // Drop the previous query before allocating its replacement, including its file metadata and excerpts.
        prepared = nil
        var best: [Int64: MeaningMatch] = [:]
        let started = DispatchTime.now().uptimeNanoseconds
        if let vector, vector.count == Vectors.dimension, !rowFile.isEmpty {
            let scores = score(vector)
            let meaning = Self.meaning(scores, rowModality, setsScale: rowSetsScale)
            for row in scores.indices {
                let file = rowFile[row], z = meaning[row]
                if z > (best[file]?.z ?? -.infinity) {
                    best[file] = MeaningMatch(z: z, cosine: Double(scores[row]), segment: rowSegment[row])
                }
            }
            vectorScanCount += 1
            lastMetrics.vectorScans = 1
        }
        lastMetrics.vectorMilliseconds = Self.elapsed(started)
        let keywordStart = DispatchTime.now().uptimeNanoseconds
        let terms = Self.terms(text)
        let identifier = isCode ? CodeLookup.identifier(text) : nil
        var patterns = identifier.map { [CodeLookup.phrase($0)] } ?? Self.patterns(terms, prefixLast: prefixLast)
        if identifier == nil {
            for index in terms.indices where terms[index].count >= 3 && !patterns[index].hasSuffix("*") {
                if try !isIndexed(patterns[index]) { patterns[index] += "*" }
            }
        }
        var words: [WordMatch] = []
        if !patterns.isEmpty {
            var seen = Set<Int64>()
            try store.db.query("""
                SELECT s.file, s.id, s.kind FROM fts JOIN segments s ON s.id = fts.rowid
                WHERE fts MATCH ? ORDER BY bm25(fts, 3.0, 1.0) LIMIT 1000
                """, [.text(patterns.joined(separator: " OR "))]) { row in
                guard seen.insert(row.int(0)).inserted else { return }
                words.append(WordMatch(file: row.int(0), segment: row.int(1),
                                       kind: SegmentKind(rawValue: row.text(2) ?? "") ?? .name))
            }
        }
        let result = PreparedQuery(text: text, vector: vector, prefixLast: prefixLast, terms: terms,
                                   identifier: identifier, patterns: patterns, meaning: best, words: words)
        prepared = result
        lastMetrics.keywordMilliseconds = Self.elapsed(keywordStart)
        return result
    }

    private func select(_ query: PreparedQuery, kinds: Set<FileKind>?, limit: Int, zGate: Double,
                        wordWeight: Double) throws -> [Selection] {
        let key = SelectionKey(kinds: kinds, limit: limit, zGate: zGate, wordWeight: wordWeight)
        if let cached = query.selections[key] { return cached }
        let allowed = { (file: Int64) in kinds == nil || self.fileKind[file].map { kinds!.contains($0) } ?? false }
        // Preserve the original per-filter 100-file keyword budget, inside the same global 1,000 FTS rows.
        let words = Array(query.words.lazy.filter { allowed($0.file) }.prefix(100))
        try keywords(words, query: query)
        let best = query.meaning
        let lookup = Self.isLookup(query.terms) || query.identifier != nil
        let (meaningWeight, wordsWeight) = lookup ? (0.5, wordWeight * 2) : (1, wordWeight)
        let hinted = Self.kindHints(query.text)
        var candidates = Set(best.lazy.filter { allowed($0.key) && $0.value.z >= zGate }.map(\.key))
        for word in words where query.coverage[word.file, default: 0] >= 0.5 { candidates.insert(word.file) }
        let scored = candidates.map { file -> (file: Int64, score: Double) in
            var score = meaningWeight * max(best[file]?.z ?? 0, 0)
                + wordsWeight * pow(query.coverage[file] ?? 0, 1.5)
            if let kind = fileKind[file], hinted.contains(kind) { score += 1 }
            return (file, score)
        }.sorted { $0.score > $1.score || ($0.score == $1.score && $0.file < $1.file) }
        let wordRank = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.element.file, ($0.offset + 1, $0.element)) })
        var selected: [Selection] = []
        for candidate in scored.prefix(limit) {
            let file = candidate.file, semantic = best[file], keyword = wordRank[file]
            let useMeaning = semantic.map { $0.z >= zGate || keyword == nil } ?? false
            guard let segment = useMeaning ? semantic?.segment : keyword?.1.segment else { continue }
            var selection = Selection(file: file, score: candidate.score, semantic: semantic, keyword: keyword,
                                      segment: segment)
            if isCode {
                let identifier = selected.count < 10 ? query.identifier : nil
                if let identifier, let found = try codeDefinition(file: file, identifier: identifier, query: query.text) {
                    selection.segment = found.segment
                    selection.focus = found.focus
                } else if keyword?.1.segment == segment || query.identifier != nil {
                    let name = query.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "()", with: "")
                    selection.focusWords = identifier == nil ? query.terms : [name.lowercased()]
                }
            }
            selected.append(selection)
        }
        if limit <= 256, query.selections.count < 16 { query.selections[key] = selected }
        return selected
    }

    /// Coverage for all newly requested files uses one compound statement per batch of 32 terms.
    /// Snippets are fetched in one FTS batch, only for files a filter actually needs.
    private func keywords(_ words: [WordMatch], query: PreparedQuery) throws {
        let missing = words.filter { !query.coveredFiles.contains($0.file) }.map(\.file)
        if !missing.isEmpty, !query.patterns.isEmpty {
            let values = Array(repeating: "(?)", count: missing.count).joined(separator: ",")
            for start in stride(from: 0, to: query.patterns.count, by: 32) {
                let patterns = Array(query.patterns[start..<min(start + 32, query.patterns.count)])
                let parts = patterns.map { _ in """
                    SELECT DISTINCT s.file FROM fts JOIN segments s ON s.id = fts.rowid
                    WHERE fts MATCH ? AND s.file IN (SELECT file FROM candidates)
                    """ }
                let sql = "WITH candidates(file) AS (VALUES \(values)) " + parts.joined(separator: " UNION ALL ")
                try store.db.query(sql, missing.map(SQLValue.int) + patterns.map(SQLValue.text)) {
                    query.coverage[$0.int(0), default: 0] += 1 / Double(query.patterns.count)
                }
            }
            query.coveredFiles.formUnion(missing)
        }
        let snippets = words.filter { !query.snippetsLoaded.contains($0.segment) }.map(\.segment)
        if !snippets.isEmpty {
            let slots = Array(repeating: "?", count: snippets.count).joined(separator: ",")
            try store.db.query("""
                SELECT rowid, snippet(fts, 1, '«', '»', '…', 12), original FROM fts
                WHERE fts MATCH ? AND rowid IN (\(slots))
                """, [.text(query.patterns.joined(separator: " OR "))] + snippets.map(SQLValue.int)) { row in
                query.snippets[row.int(0)] = row.text(2).flatMap { SearchText.snippet($0, terms: query.terms) } ?? row.text(1)
            }
            query.snippetsLoaded.formUnion(snippets)
        }
    }

    /// File metadata, segment locations and code text are joined once for up to 400 IDs, below SQLite's bind limit.
    private func records(for segments: [Int64], query: PreparedQuery) throws -> [Int64: HitRecord] {
        var records = query.records
        let missing = Array(Set(segments).subtracting(records.keys)).sorted()
        for start in stride(from: 0, to: missing.count, by: 400) {
            let ids = Array(missing[start..<min(start + 400, missing.count)])
            let slots = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let text = isCode ? "coalesce(fts.original, fts.body)" : "NULL"
            let join = isCode ? "LEFT JOIN fts ON fts.rowid = s.id" : ""
            try store.db.query("""
                SELECT s.id, s.kind, s.loc, s.loc_end, s.excerpt, f.path, f.kind, f.mtime, f.size, f.info, \(text)
                FROM segments s JOIN files f ON f.id = s.file \(join) WHERE s.id IN (\(slots))
                """, ids.map(SQLValue.int)) { row in
                var info: [String: String] = [:]
                if let json = row.text(9)?.data(using: .utf8) {
                    info = (try? JSONSerialization.jsonObject(with: json) as? [String: String]) ?? [:]
                }
                let record = HitRecord(segment: SegmentKind(rawValue: row.text(1) ?? "") ?? .name,
                                       loc: row.isNull(2) ? nil : row.double(2),
                                       locEnd: row.isNull(3) ? nil : row.double(3), excerpt: row.text(4),
                                       path: row.text(5) ?? "", kind: FileKind(rawValue: row.text(6) ?? "") ?? .doc,
                                       modified: row.double(7), size: row.int(8), info: info, text: row.text(10))
                records[row.int(0)] = record
                if query.records.count < 1024 { query.records[row.int(0)] = record }
                lastMetrics.hydratedRows += 1
            }
        }
        return records
    }

    /// An identifier lookup stays limited to ten results and 300 stretches per file, as before.
    private func codeDefinition(file: Int64, identifier: [String], query: String) throws -> (segment: Int64, focus: Double)? {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "()", with: "")
        var best: (segment: Int64, line: Int, strength: Int)?
        try store.db.query("""
            SELECT s.id, s.loc, coalesce(fts.original, fts.body) FROM fts JOIN segments s ON s.id = fts.rowid
            WHERE fts MATCH ? AND s.file = ? ORDER BY s.loc LIMIT 300
            """, [.text(CodeLookup.phrase(identifier)), .int(file)]) { row in
            guard best?.strength ?? 0 < 2, let text = row.text(2),
                  let found = CodeLookup.definition(of: name, in: text, first: Int(row.double(1))) else { return }
            if found.strength > (best?.strength ?? 0) { best = (row.int(0), found.line, found.strength) }
        }
        return best.map { ($0.segment, Double($0.line)) }
    }

    private static func elapsed(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// Codes and IDs ("K7Q2LM", "TRX50") and long numbers ("4815162342": an order, a phone number) mean nothing to an
    /// embedding but everything to keyword search: a query made of them weighs words double and meaning half. Numbers
    /// count since 2026-10-09, when text of digits lost its vectors (`SearchText.hasWords`): a number in a data dump fell
    /// below unrelated meaning matches.
    static func isLookup(_ terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy {
            $0.contains(where: \.isNumber) && ($0.contains(where: \.isLetter) || $0.count >= 4)
        }
    }

    /// How many of `hits` (best first) are strong: scoring at least `ratio` × the top hit. The rest pass the gates but
    /// trail far behind, and the app folds them under "weaker matches". On both evals (2026-10-07), 0.5 cut the list
    /// from 26.2 to 5.7 results per query and never folded an expected answer.
    public static func strongCount(_ hits: [SearchHit], ratio: Double = 0.5) -> Int {
        guard let top = hits.first?.score, top > 0 else { return hits.count }
        return hits.prefix { $0.score >= top * ratio }.count
    }

    /// Cosine similarity of `query` with every stored vector (all are L2-normalized): a matrix-vector product, done a
    /// block of rows at a time, each block turned into float32 first.
    private func score(_ query: [Float]) -> [Float] {
        let rows = rowFile.count
        var scores = [Float](repeating: 0, count: rows)
        guard let matrix, rows > 0 else { return scores }
        query.withUnsafeBufferPointer { query in
            scores.withUnsafeMutableBufferPointer { scores in
                var row = 0
                while row < rows {
                    let count = min(VectorStorage.blockRows, rows - row)
                    Vectors.floats(fromHalf: matrix.halves + row * Vectors.dimension, count: count * Vectors.dimension,
                                   to: matrix.block)
                    // (count × 768) · (768 × 1)
                    Vectors.scores(of: matrix.block, count: count, query: query.baseAddress!,
                                   into: scores.baseAddress! + row)
                    row += count
                }
            }
        }
        return scores
    }

    /// This query's meaning scores: each vector's cosine similarity minus the average of its modality (text, image and
    /// audio vectors can sit at slightly different levels for the same query), in standard deviations of all of them
    /// together. Within a modality that's the model's own order. Scaling each modality by its own deviation instead
    /// inflated the narrow ones and buried PDF pages under pictures (2026-10-08, on the three evals: 91 → 94 of 105
    /// queries with the right answer first).
    ///
    /// The scale (the averages and the deviation) comes from the vectors in `setsScale` (all by default): `search` leaves
    /// out the later pages of long files, which are scored on it but don't move it. A book's hundreds of pages pulled the
    /// text average down for every query, and documents rose over screenshots everywhere (2026-10-09, the testbed's long
    /// files finished: real eval 24 → 22 of 26 first; 24 with the scale kept).
    static func meaning(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Double] {
        let means = modalityMeans(scores, modality, setsScale: setsScale)
        let centered = zip(scores, modality).map { Double($0) - means[$1, default: 0] }
        var count = 0.0, sum = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            count += 1
            sum += centered[row]
        }
        let mean = sum / max(count, 1)
        var squares = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            squares += (centered[row] - mean) * (centered[row] - mean)
        }
        let deviation = max((squares / max(count, 1)).squareRoot(), 0.02)
        return centered.map { ($0 - mean) / deviation }
    }

    /// The average score of each modality for this query. Small groups (< 20 vectors) take the average of all.
    static func modalityMeans(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Modality: Double] {
        var sum: [Modality: Double] = [:], count: [Modality: Int] = [:]
        for row in scores.indices where setsScale?[row] ?? true {
            sum[modality[row], default: 0] += Double(scores[row])
            count[modality[row], default: 0] += 1
        }
        let all = sum.values.reduce(0, +) / Double(max(count.values.reduce(0, +), 1))
        var out: [Modality: Double] = [:]
        for modality in Modality.allCases {
            if let n = count[modality], n >= 20 {
                out[modality] = sum[modality]! / Double(n)
            } else {
                out[modality] = all
            }
        }
        return out
    }

    /// The text of a page, a document's passage or a screenshot's OCR, as it's written: the preview shows the part of a
    /// document that matched.
    public func text(ofSegment id: Int64) throws -> String? {
        var text: String?
        try store.db.query("SELECT coalesce(original, body) FROM fts WHERE rowid = ?", [.int(id)]) { text = $0.text(0) }
        return text
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "that", "this",
        "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be",
        "it", "its", "some", "any", "find", "show", "file", "files", "photo", "photos", "picture", "image", "images",
        "screenshot", "screenshots", "video", "videos", "pdf", "document", "documents", "recording",
        // Bengali and Arabic (normalized, as `terms` sees them)
        "এবং", "ও", "এই", "সেই", "একটি", "আমার", "থেকে", "জন্য", "সাথে", "মধ্যে", "কোথায়", "কোন", "কী", "কি", "যে",
        "ছবি", "স্ক্রিনশট", "ভিডিও", "ফাইল", "পিডিএফ",
        "في", "من", "على", "الى", "عن", "مع", "هذا", "هذه", "ذلك", "التي", "الذي", "اين", "ما",
        "صورة", "صور", "لقطة", "شاشة", "فيديو", "ملف", "مستند",
    ]

    /// The content words of a query, normalized as keyword search keeps its text (`SearchText`). Kind words
    /// ("screenshot", "video") and stopwords are dropped: they describe what to look for, not what's in it. Words of
    /// two letters or more count; a Bengali letter with its vowel sign ("মা") is two.
    public static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return SearchText.normalized(text).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.unicodeScalars.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    /// FTS5 patterns for the query's words: quoted, and as prefixes for the last word while it's being typed and for
    /// words of languages that attach endings (`SearchText.inflects`). `search` makes a word that's in no file a
    /// prefix too.
    static func patterns(_ terms: [String], prefixLast: Bool) -> [String] {
        terms.enumerated().map { index, term in
            let prefix = (prefixLast && index == terms.count - 1) || SearchText.inflects(term)
            return "\"\(term)\"" + (prefix ? "*" : "")
        }
    }

    /// Whether keyword search finds `pattern` in any file.
    private func isIndexed(_ pattern: String) throws -> Bool {
        var found = false
        try store.db.query("SELECT 1 FROM fts WHERE fts MATCH ? LIMIT 1", [.text(pattern)]) { _ in found = true }
        return found
    }

    /// The query's words as an FTS5 OR-query.
    public static func ftsQuery(_ text: String, prefixLast: Bool = false) -> String? {
        let words = terms(text)
        guard !words.isEmpty else { return nil }
        return patterns(words, prefixLast: prefixLast).joined(separator: " OR ")
    }

    static let kindWords: [String: FileKind] = [
        "screenshot": .screenshot, "screenshots": .screenshot, "photo": .image, "photos": .image, "picture": .image,
        "pictures": .image, "image": .image, "images": .image, "pdf": .pdf, "pdfs": .pdf, "paper": .pdf,
        "papers": .pdf, "document": .doc, "documents": .doc, "note": .doc, "notes": .doc, "video": .video,
        "videos": .video, "clip": .video, "movie": .video, "audio": .audio, "song": .audio, "podcast": .audio,
        "voice": .audio, "sound": .audio,
        "স্ক্রিনশট": .screenshot, "ছবি": .image, "পিডিএফ": .pdf, "নোট": .doc, "ভিডিও": .video, "অডিও": .audio,
        "গান": .audio, "রেকর্ডিং": .audio,
        "لقطة": .screenshot, "صورة": .image, "صور": .image, "مستند": .doc, "ملاحظات": .doc, "فيديو": .video,
        "مقطع": .video, "صوت": .audio, "تسجيل": .audio, "اغنية": .audio,
    ]

    /// Kinds the query asks for ("…in a video", "screenshot of…", "ভিডিওতে"): a soft boost, not a filter. Bengali
    /// attaches case endings, so a Bengali kind word also counts at the start of a longer word.
    static func kindHints(_ text: String) -> Set<FileKind> {
        Set(SearchText.normalized(text).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .compactMap { word in
                kindWords[word] ?? kindWords.first { key, _ in
                    SearchText.inflects(key) && key.unicodeScalars.count >= 3 && word.hasPrefix(key)
                }?.value
            })
    }
}
