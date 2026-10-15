import AppKit
import Testing
@testable import DigUpApp

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ImageCacheTests {
    @Test func duplicateRequestsShareOneRenderAndOneImage() async throws {
        let cache = ImageCache(megabytes: 1, count: 10)
        let probe = RenderProbe()
        let first = Task { await cache.load("same", scale: 2) { await probe.render() } }
        let second = Task { await cache.load("same", scale: 2) { await probe.render() } }
        await probe.waitForStarts(1)
        await probe.finishAll()
        let a = try #require(await first.value)
        let b = try #require(await second.value)
        #expect(a === b)
        #expect(await probe.starts == 1)
        #expect(cache.cached("same") === a)
    }

    @Test func renderingIsLimitedToFourAtATime() async {
        let cache = ImageCache(megabytes: 1, count: 20)
        let probe = RenderProbe()
        let tasks = (0..<12).map { number in
            Task { await cache.load("file-\(number)", scale: 1) { await probe.render() } }
        }
        for batch in 1...3 {
            await probe.waitForStarts(batch * 4)
            await probe.finishAll()
        }
        for task in tasks { #expect(await task.value != nil) }
        #expect(await probe.peak == 4)
        #expect(await probe.starts == 12)
    }

    @Test func clearingCancelsQueuedRendersAndRejectsOldImages() async {
        let cache = ImageCache(megabytes: 1, count: 20)
        let probe = RenderProbe()
        var entered = 0
        let tasks = (0..<12).map { number in
            Task {
                entered += 1
                return await cache.load("file-\(number)", scale: 1) { await probe.render() }
            }
        }
        await probe.waitForStarts(4)
        // Let every caller enter the cache, including those waiting for a rendering slot.
        while entered < tasks.count { await Task.yield() }
        cache.clear()
        await probe.finishAll()
        for task in tasks { #expect(await task.value == nil) }
        #expect(await probe.starts == 4)
        for number in 0..<12 { #expect(cache.cached("file-\(number)") == nil) }
    }

    @Test func aNewRequestSurvivesAnOlderGenerationFinishing() async throws {
        let cache = ImageCache(megabytes: 1, count: 10)
        let probe = RenderProbe()
        let old = Task { await cache.load("file", scale: 1) { await probe.render() } }
        await probe.waitForStarts(1)
        cache.clear()
        let fresh = Task { await cache.load("file", scale: 1) { await probe.render() } }
        await probe.waitForStarts(2)
        await probe.finishAll()
        #expect(await old.value == nil)
        let image = try #require(await fresh.value)
        #expect(cache.cached("file") === image)
    }
}

private actor RenderProbe {
    private(set) var starts = 0
    private(set) var peak = 0
    private var active = 0
    private var renders: [CheckedContinuation<CGImage?, Never>] = []
    private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func render() async -> CGImage? {
        starts += 1
        active += 1
        peak = max(peak, active)
        let ready = observers.filter { starts >= $0.count }
        observers.removeAll { starts >= $0.count }
        ready.forEach { $0.continuation.resume() }
        return await withCheckedContinuation { renders.append($0) }
    }

    func waitForStarts(_ count: Int) async {
        guard starts < count else { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func finishAll() {
        let image = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let pending = renders
        renders = []
        active -= pending.count
        pending.forEach { $0.resume(returning: image) }
    }
}
