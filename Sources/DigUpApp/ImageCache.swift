import AppKit

/// A bounded image cache with shared requests. Only four images render at once, even during fast scrolling.
/// Main-actor state stays separate from the system image generators, which run off the main actor.
final class ImageCache {
    private let images = NSCache<NSString, NSImage>()
    private var pending: [String: (id: UUID, task: Task<CGImage?, Never>)] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var generation = 0

    init(megabytes: Int, count: Int) {
        images.totalCostLimit = megabytes << 20
        images.countLimit = count
    }

    func cached(_ key: String) -> NSImage? {
        images.object(forKey: key as NSString)
    }

    func load(_ key: String, scale: CGFloat,
              generate: @escaping @Sendable () async -> CGImage?) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cached(key) { return image }
        let current = generation
        let task: Task<CGImage?, Never>
        let id: UUID
        if let existing = pending[key] {
            task = existing.task
            id = existing.id
        } else {
            id = UUID()
            task = Task {
                await acquire()
                defer { release() }
                guard !Task.isCancelled else { return nil }
                return await generate()
            }
            pending[key] = (id, task)
        }
        let picture = await task.value
        // Closing the last search surface clears this cache. Old work must never refill it.
        guard current == generation else { return nil }
        if pending[key]?.id == id { pending[key] = nil }
        guard !Task.isCancelled, let picture else { return nil }
        if let image = cached(key) { return image }
        let image = NSImage(cgImage: picture, size: NSSize(width: CGFloat(picture.width) / scale,
                                                         height: CGFloat(picture.height) / scale))
        images.setObject(image, forKey: key as NSString, cost: picture.bytesPerRow * picture.height)
        return image
    }

    func clear() {
        generation += 1
        images.removeAllObjects()
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
    }

    private func acquire() async {
        if active < 4 {
            active += 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    private func release() {
        if waiting.isEmpty {
            active -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
