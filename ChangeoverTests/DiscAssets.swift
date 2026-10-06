import Foundation

/// #0224 — the captured disc material that must not live in this repository.
///
/// `Changeover` is a **public** GitHub repository, and the disc corpus under
/// `ChangeoverTests/Fixtures/discs/` grew to hold things that have no business
/// being published: 76 JPEG stills of DVD menu screens (studio artwork), raw
/// `.IFO` files copied verbatim off a disc, and `ocr.json` files carrying the
/// authored menu and chapter text those stills show. Durations, chapter counts,
/// sector ranges and VM opcodes are facts about a disc's structure; a frame of
/// its menu is an excerpt of the film.
///
/// So the expressive material moves out of git and is reached by path, and the
/// tests that need it **skip when it is absent**. A clean clone still builds
/// and still runs the whole structural suite; a machine with the corpus runs
/// more.
///
/// ## Where it lives
///
/// | Location | Role |
/// |---|---|
/// | `/Volumes/Media/Changeover/Fixtures` on joe | source of truth, beside where discs are captured |
/// | `~/Documents/Changeover/Fixtures` | backup, synced by iCloud between the user's Macs |
/// | `~/changeover-fixtures` on gordon | the test mirror, a plain rsync |
///
/// `CHANGEOVER_DISC_ASSETS` overrides all of it, so a run can be pointed
/// anywhere without editing code.
///
/// ## Why the test mirror is not the iCloud copy
///
/// gordon has `optimize-storage = 1` and its iCloud container is full of
/// `.icloud` placeholders — entries that exist by name and hold no data until
/// something downloads them. **`FileManager.fileExists` returns `true` for a
/// placeholder**, so a naive availability check passes and every read then
/// stalls on a download or fails offline. `isReadable` below is why this type
/// exists at all rather than being a one-line path constant.
///
/// ## The hazard this must not create
///
/// A suite that silently skips is a suite that silently stops testing. This
/// project already knows the shape: a `-only-testing:` selector that matches
/// nothing runs zero tests and still prints `** TEST SUCCEEDED **`. Asset
/// gating is the same trap with a new cause — the corpus goes missing, forty
/// tests quietly skip, the run is green and nobody notices for a month. So
/// `DiscAssetAvailabilityTests` always runs and always reports what it found,
/// and a thin run has to look thin.
enum DiscAssets {

    /// Where a run may be pointed, in order of preference.
    ///
    /// The environment variable first, so a machine can say for itself without
    /// this list growing a case per Mac.
    static var searchPaths: [String] {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["CHANGEOVER_DISC_ASSETS"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            paths.append(override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append("\(home)/changeover-fixtures")
        paths.append("/Volumes/Media/Changeover/Fixtures")
        paths.append("\(home)/Documents/Changeover/Fixtures")
        return paths
    }

    /// The file that makes a directory a captured disc rather than a folder.
    ///
    /// Required, and that requirement is the whole of this check. `Tools/
    /// capture-disc.sh` writes `scan.json` for every capture, so its presence
    /// is what separates a corpus from a directory that merely has
    /// subdirectories in it.
    static let captureMarker = "scan.json"

    /// The first search path holding at least one **captured disc**, or `nil`.
    ///
    /// The marker check is not pedantry. `~/changeover-fixtures` is also
    /// `AppSettings.menuArchivePath` — where the app writes menu material per
    /// disc — so on a machine that has merely *run* the app-hosted tests it
    /// fills with stub directories named after test disc ids (`disc-a`, `x`,
    /// `untitled`). gordon had eleven of them, each a lone `naming.json`.
    /// Counting those reported "11 disc(s)" on a machine with no corpus at all,
    /// which is precisely the false green this type exists to prevent.
    static var root: URL? {
        for path in searchPaths {
            let url = URL(fileURLWithPath: path)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path)
            else { continue }
            let captured = names.contains { name in
                !name.hasPrefix(".")
                    && isReadable(url.appendingPathComponent(name)
                        .appendingPathComponent(captureMarker))
            }
            if captured { return url }
        }
        return nil
    }

    /// Whether asset-backed tests can run at all.
    static var isAvailable: Bool { root != nil }

    /// Every **captured** disc in the corpus, sorted. A directory without a
    /// readable `scan.json` is not one, however it got there.
    static var slugs: [String] {
        guard let root,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .filter { isReadable(root.appendingPathComponent($0).appendingPathComponent(captureMarker)) }
            .sorted()
    }

    /// A file inside one disc's directory, **only when its bytes are actually
    /// here**.
    ///
    /// `nil` for a file that does not exist *and* for an iCloud placeholder,
    /// because the two are the same thing to a test: no data. Returning a URL
    /// for a placeholder would turn a missing-corpus skip into a mid-test
    /// network stall.
    static func file(_ relativePath: String, inDisc slug: String) -> URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent(slug).appendingPathComponent(relativePath)
        return isReadable(url) ? url : nil
    }

    /// Whether `url` holds real bytes right now.
    ///
    /// Three ways a path can look present and not be:
    ///
    /// 1. it does not exist;
    /// 2. iCloud has evicted it, leaving a sibling `.<name>.icloud` stub — the
    ///    shape gordon's container is full of;
    /// 3. it exists with zero length, which no fixture ever legitimately has.
    static func isReadable(_ url: URL) -> Bool {
        let fm = FileManager.default
        let placeholder = url
            .deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        if fm.fileExists(atPath: placeholder.path) { return false }
        guard fm.fileExists(atPath: url.path),
              let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    /// One line describing what a run found, for the summary a person reads.
    static func summary() -> String {
        guard let root else {
            return "disc assets: NONE — asset-backed tests skipped. "
                + "Set CHANGEOVER_DISC_ASSETS or mirror the corpus to ~/changeover-fixtures."
        }
        return "disc assets: \(slugs.count) disc(s) at \(root.path)"
    }
}
