import DigUpKit
import Testing
@testable import DigUpApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SearchModelTests {
    @Test func rapidTypingOnlyEmbedsTheLatestQuery() async throws {
        let engine = SearchProbe(), model: SearchModel
        model = SearchModel(engine: engine)
        for text in ["b", "bu", "bud", "budget"] {
            model.query = text
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.embedded == ["budget"])
        #expect(engine.words == ["budget"])
        #expect(engine.pages == ["budget"])
        #expect(!model.isSearching)
    }

    @Test func kindChangesReuseTheVectorAndSkipTheKeywordStage() async throws {
        let engine = SearchProbe(), model: SearchModel
        model = SearchModel(engine: engine)
        model.query = "budget"
        try await Task.sleep(for: .milliseconds(300))
        model.filter = .documents
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.embedded == ["budget"])
        #expect(engine.words == ["budget"])
        #expect(engine.pages == ["budget", "budget"])
        #expect(engine.kinds.last! == [.pdf, .doc])
        #expect(!model.isSearching)
    }

    @Test func switchingToCodeEmbedsWithTheCodePrompt() async throws {
        let engine = SearchProbe(), model: SearchModel
        model = SearchModel(engine: engine)
        model.query = "budget"
        try await Task.sleep(for: .milliseconds(300))
        model.filter = .code
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.embedded == ["budget", "budget"])
        #expect(engine.codePrompts == [false, true])
    }

    @Test func resetCancelsWorkBeforeItStarts() async throws {
        let engine = SearchProbe(), model: SearchModel
        model = SearchModel(engine: engine)
        model.query = "budget"
        model.reset()
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.embedded.isEmpty)
        #expect(engine.words.isEmpty)
        #expect(engine.pages.isEmpty)
        #expect(!model.hasResults)
        #expect(!model.isSearching)
    }

    @Test func lateKeywordResultsCannotStartAnOldQueryEmbedding() async throws {
        let engine = SearchProbe(), model: SearchModel
        model = SearchModel(engine: engine)
        engine.onWords = {
            model.query = "latest"
            engine.onWords = nil
        }
        model.query = "old"
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.embedded == ["latest"])
        #expect(engine.pages == ["latest"])
        #expect(!model.isSearching)
    }
}

@MainActor private final class SearchProbe: WindowSearching {
    var hasCode = true
    var embedded: [String] = []
    var words: [String] = []
    var pages: [String] = []
    var kinds: [Set<FileKind>?] = []
    var codePrompts: [Bool] = []
    var onWords: (() -> Void)?

    func open(_ row: ResultRow) {}
    func embedAhead(_ text: String, code: Bool) {}

    func embedQuery(_ text: String, code: Bool) async -> Engine.QueryVector? {
        embedded.append(text)
        codePrompts.append(code)
        return Engine.QueryVector(values: [1], source: "test")
    }

    func search(_ text: String, vector: Engine.QueryVector?, prefixLast: Bool, kinds: Set<FileKind>?,
                limit: Int, code: Bool) async -> [SearchHit] {
        words.append(text)
        onWords?()
        return []
    }

    func searchWindow(_ text: String, vector: Engine.QueryVector?, kinds: Set<FileKind>?, limit: Int,
                      code: Bool) async -> SearchPage {
        pages.append(text)
        self.kinds.append(kinds)
        return SearchPage(all: [], hits: [])
    }
}
