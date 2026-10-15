import Foundation
import Testing
@testable import DigUpKit

@Suite struct SearchPerformanceTests {
    private func withStore(_ body: (IndexStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(IndexStore(directory: folder))
    }

    private func add(_ number: Int, to store: IndexStore, kind: FileKind = .doc, text: String = "budget review",
                     vector: [Float]? = nil, segment: SegmentKind = .chunk, loc: Double? = 1) throws -> Int64 {
        let id = try store.insert(Candidate(path: "/fixtures/entry-\(number).txt", kind: kind, size: Int64(number),
                                            mtime: Double(number), inode: UInt64(number), device: 1))
        try store.addSegment(file: id, kind: segment, modality: .text, loc: loc, text: text, vector: vector)
        return id
    }

    private func vector(_ first: Float) -> [Float] {
        var vector = [Float](repeating: 0, count: 768)
        vector[0] = first
        vector[1] = sqrt(max(0, 1 - first * first))
        return vector
    }

    @Test func aFilteredPageFindsMatchesBeyondTheAllKindsLimitWithoutRescanning() throws {
        try withStore { store in
            try store.db.transaction {
                for number in 0..<1000 {
                    _ = try add(number, to: store, kind: (140..<160).contains(number) ? .image : .doc,
                                text: "unrelated notes", vector: vector(number < 160 ? 0.6 : 0))
                }
            }
            let searcher = try Searcher(store: store)
            let query = vector(1)
            let page = try searcher.searchPage("ocean", queryVector: query, kinds: [.image], limit: 120)
            #expect(page.all.count == 120)
            #expect(page.all.allSatisfy { $0.kind == .doc })
            #expect(page.hits.count == 20)
            #expect(page.hits.allSatisfy { $0.kind == .image })
            #expect(searcher.lastMetrics.vectorScans == 1)
            #expect(searcher.vectorScanCount == 1)
            let docs = try searcher.searchPage("ocean", queryVector: query, kinds: [.doc], limit: 120)
            #expect(docs.hits.map(\.path) == page.all.map(\.path))
            #expect(searcher.vectorScanCount == 1)
            #expect(searcher.lastMetrics.reusedQuery)
            #expect(searcher.lastMetrics.hydratedRows == 0)
        }
    }

    @Test func keywordBudgetsAndRanksStayLocalToEachFilter() throws {
        try withStore { store in
            try store.db.transaction {
                for number in 0..<500 {
                    _ = try add(number, to: store, kind: number < 200 ? .doc : .image)
                }
            }
            let searcher = try Searcher(store: store, loadVectors: false)
            let page = try searcher.searchPage("budget", queryVector: nil, kinds: [.image], limit: 120)
            #expect(page.all.count == 100)
            #expect(page.all.allSatisfy { $0.kind == .doc })
            #expect(page.hits.count == 100)
            #expect(page.hits.allSatisfy { $0.kind == .image })
            #expect(page.hits.map(\.keywordRank) == (1...100).map { Optional($0) })
            let fresh = try Searcher(store: store, loadVectors: false)
            let standalone = try fresh.search("budget", queryVector: nil, kinds: [.image], limit: 120)
            #expect(page.hits.map(\.path) == standalone.map(\.path))
            #expect(page.hits.map(\.score) == standalone.map(\.score))
        }
    }

    @Test func metadataHydrationUsesBatchesInsteadOfOneReadPerHit() throws {
        try withStore { store in
            try store.db.transaction { for number in 0..<150 { _ = try add(number, to: store) } }
            let searcher = try Searcher(store: store, loadVectors: false)
            let hits = try searcher.search("budget", queryVector: nil, limit: 120)
            #expect(hits.count == 100)
            #expect(searcher.lastMetrics.hydratedRows == 100)
            #expect(searcher.lastMetrics.sqlStatements <= 8)
            let again = try searcher.search("budget", queryVector: nil, limit: 120)
            #expect(again.map(\.path) == hits.map(\.path))
            #expect(searcher.lastMetrics.sqlStatements == 1)   // only the index revision check
            #expect(searcher.lastMetrics.hydratedRows == 0)
        }
    }

    @Test func changingFilterOrderCannotLeakKeywordBoostsIntoSemanticResults() throws {
        try withStore { store in
            try store.db.transaction {
                for number in 0..<1000 {
                    _ = try add(number, to: store, kind: number < 100 ? .image : .doc,
                                text: number <= 100 ? "budget review" : "unrelated notes",
                                vector: vector(number == 100 ? 0.6 : 0))
                }
            }
            let searcher = try Searcher(store: store)
            let filtered = try #require(searcher.search("budget", queryVector: vector(1), kinds: [.doc]).first)
            let all = try #require(searcher.search("budget", queryVector: vector(1)).first)
            let fresh = try Searcher(store: store)
            let expected = try #require(fresh.search("budget", queryVector: vector(1)).first)
            #expect(filtered.path == all.path)
            #expect(filtered.score > all.score)
            #expect(all.score == expected.score)
            #expect(all.keywordRank == nil)
        }
    }

    @Test func hydrationSplitsLargePagesBelowTheSQLiteBindLimit() throws {
        try withStore { store in
            try store.db.transaction {
                for number in 0..<4600 {
                    _ = try add(number, to: store, text: "unrelated notes", vector: vector(number < 600 ? 0.6 : 0))
                }
            }
            let searcher = try Searcher(store: store)
            let hits = try searcher.search("ocean", queryVector: vector(1), limit: 600)
            #expect(hits.count == 600)
            #expect(searcher.lastMetrics.hydratedRows == 600)
            #expect(searcher.lastMetrics.sqlStatements <= 8)
        }
    }

    @Test func localAndExternalWritesInvalidateCachedKeywordResults() throws {
        try withStore { store in
            _ = try add(1, to: store)
            let searcher = try Searcher(store: store, loadVectors: false)
            #expect(try searcher.search("budget", queryVector: nil).count == 1)
            _ = try add(2, to: store)
            #expect(try searcher.search("budget", queryVector: nil).count == 2)
            #expect(!searcher.lastMetrics.reusedQuery)
            let helper = try IndexStore(directory: store.directory)
            _ = try add(3, to: helper)
            #expect(try searcher.search("budget", queryVector: nil).count == 3)
            #expect(!searcher.lastMetrics.reusedQuery)
            try helper.db.run("DELETE FROM files WHERE path = ?", [.text("/fixtures/entry-1.txt")])
            #expect(try searcher.search("budget", queryVector: nil).count == 2)
        }
    }

    @Test func externalWritesRefreshVectorsAndIdleReleaseDropsTheQueryCache() throws {
        try withStore { store in
            try store.db.transaction {
                for number in 0..<100 { _ = try add(number, to: store, vector: vector(number == 0 ? 0.6 : 0)) }
            }
            let searcher = try Searcher(store: store)
            _ = try searcher.search("ocean", queryVector: vector(1))
            let helper = try IndexStore(directory: store.directory)
            _ = try add(100, to: helper, vector: vector(0.6))
            let changed = try searcher.search("ocean", queryVector: vector(1))
            #expect(changed.contains { $0.path == "/fixtures/entry-100.txt" })
            #expect(searcher.vectorCount == 101)
            #expect(searcher.vectorScanCount == 2)
            searcher.releaseVectors()
            #expect(searcher.vectorCount == 0)
            _ = try searcher.search("budget", queryVector: nil)
            #expect(!searcher.lastMetrics.reusedQuery)
            #expect(!searcher.vectorsLoaded)
            _ = try searcher.search("ocean", queryVector: vector(1))
            #expect(searcher.vectorScanCount == 3)
        }
    }

    @Test func manyQueryTermsUseBoundedCompoundCoverageStatements() throws {
        try withStore { store in
            let text = (0..<45).map { "term\($0)" }.joined(separator: " ")
            _ = try add(1, to: store, text: text)
            let searcher = try Searcher(store: store, loadVectors: false)
            let hits = try searcher.search(text, queryVector: nil)
            #expect(hits.count == 1)
            #expect(abs((hits.first?.score ?? 0) - 4) < 0.000_001)
        }
    }

    @Test func codeDefinitionsStillWinOverUsagesAndKeepTheirLine() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-code-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(directory: folder, file: IndexStore.codeFile)
        let id = try store.insert(Candidate(path: "/fixtures/auth.swift", kind: .code, size: 400,
                                            mtime: 1, inode: 1, device: 1))
        try store.addSegment(file: id, kind: .lines, modality: .text, loc: 1, locEnd: 3,
                             text: "let token = refreshAccessToken()")
        try store.addSegment(file: id, kind: .lines, modality: .text, loc: 40, locEnd: 43,
                             text: "// Refresh credentials\nfunc refreshAccessToken() -> String {\n  return token\n}")
        let searcher = try Searcher(store: store, loadVectors: false)
        let hit = try #require(searcher.search("refreshAccessToken", queryVector: nil).first)
        #expect(hit.loc == 40)
        #expect(hit.focus == 41)
    }
}
