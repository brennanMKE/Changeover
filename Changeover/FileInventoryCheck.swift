import Foundation

/// §7.2 — where the "what is actually *in* that file?" probe stands for the
/// library copy the duplicate check found.
///
/// A sibling of `LibraryCheck`, and file-scope `nonisolated` for the same
/// reason: `StartGate.decideUpgrade` is a pure function that takes this as a
/// plain value with no actor-isolation crossing.
///
/// `.unavailable` is a distinct case on purpose and is **never** collapsed
/// into "nothing to upgrade": `ffmpeg` not installed, an unreadable file and
/// a file with nothing to gain are three different sentences, and only the
/// last one is good news.
nonisolated enum FileInventoryCheck: Equatable, Sendable {
    case idle
    case checking(path: String)
    case done(path: String, LibraryFileInventory)
    /// No `ffprobe`, or it could not read the file. `reason` is shown.
    case unavailable(path: String, reason: String)

    var inventory: LibraryFileInventory? {
        if case .done(_, let inventory) = self { return inventory }
        return nil
    }

    /// The file this check is about, whatever state it is in.
    var path: String? {
        switch self {
        case .idle: return nil
        case .checking(let path), .done(let path, _), .unavailable(let path, _): return path
        }
    }
}

/// §7.2 — what re-runs the file probe. A `Hashable` pair so the Confirm
/// step's `.task(id:)` fires exactly when the matched file changes, and never
/// on an unrelated redraw.
nonisolated struct FileInventoryKey: Hashable, Sendable {
    let path: String
    let ffprobePath: String
}
