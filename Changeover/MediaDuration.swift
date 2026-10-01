import Foundation
import AVFoundation

/// #0187 — how long a video file already in the library runs.
///
/// `AVURLAsset` reads the container's own duration field, not the media: for
/// an MP4 that is the `moov` atom, a few kilobytes, and nothing is decoded.
/// Over SMB it is a seek and a small read rather than a transfer.
///
/// `nil` for anything it cannot read: a file that has gone, a container it
/// does not understand, a mount that has dropped. `LibraryExtras.verdicts`
/// treats that as "unknown", never as "absent", so an unreadable file leaves
/// the disc's copy looking importable — the safe direction, because offering a
/// re-encode the user can cancel is cheaper than silently losing an extra.
nonisolated enum MediaDuration {

    /// `async`, and awaited from `LibraryProbe`'s already-`@concurrent`
    /// runner. The synchronous `AVURLAsset.duration` was deprecated in macOS
    /// 13 because it blocks on exactly the I/O this does — a seek into a file
    /// that may be on a NAS — and this project's whole reason for marking the
    /// probe `@concurrent` is that such work must not run on the main actor.
    /// Taking the deprecated call to avoid threading `async` through one
    /// private function would have been borrowing against the same mistake.
    static func seconds(ofFileAt path: String) async -> Int? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let duration = try? await asset.load(.duration) else { return nil }
        guard duration.isValid, !duration.isIndefinite, duration.seconds.isFinite else { return nil }
        let seconds = Int(duration.seconds.rounded())
        return seconds > 0 ? seconds : nil
    }
}
