import Foundation

/// A file's own facts, as the crawl records them (`FileSystem.info`).
struct FileInfo {
    let isRegular: Bool   // not a link, device or socket
    let size: Int64
    let mtime: Double     // seconds since 1970, with the fraction the file system keeps
    let inode: UInt64
    let device: UInt64
    /// A cloud placeholder whose contents would be downloaded on read (never read).
    let dataless: Bool
}

extension Data {
    /// Atomically replaces a file so readers see either the old contents or the new contents.
    public func writeReplacing(_ url: URL) throws {
        try write(to: url, options: .atomic)
    }
}

/// The model and index folders on this Mac.
public enum AppPaths {
    /// ~/Library/Application Support/DigUp.
    public static var applicationSupport: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/DigUp")
    }

    /// The default index folder (".noindex" keeps Spotlight out of it on a Mac).
    public static var defaultIndex: URL {
        return applicationSupport.appendingPathComponent("index.noindex")
    }
}
