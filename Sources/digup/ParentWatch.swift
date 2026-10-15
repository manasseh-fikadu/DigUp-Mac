import Foundation

/// The commands an app runs as its helpers (`index-service`, `worker`, `download-model`,
/// `estimate --json`) end when the app does. They stop when their stdin closes, but only between jobs, and `estimate`
/// reads no stdin at all: after a quit, a force quit or a crash, one could go on walking folders or sit in a file for
/// minutes with no one listening. A kernel event ends the helper as soon as its parent exits.
///
/// It exits with `_exit`, as a kill would: there's no one to report to, and a job cut short is simply done again
/// (SQLite keeps the index whole; the next helper clears the scratch folder).
enum ParentWatch {
    nonisolated(unsafe) private static var source: DispatchSourceProcess?

    static func start() {
        let parent = getppid()
        guard parent != 1 else { _exit(0) }   // launchd took it in: the app is gone already
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit,
                                                      queue: .global(qos: .utility))
        source.setEventHandler { _exit(0) }
        source.resume()
        self.source = source
        if getppid() != parent { _exit(0) }   // it went before the watch began
    }
}
