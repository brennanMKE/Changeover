import Foundation

/// #0211 — where to read this disc *right now*.
///
/// `DiscInsertion.isMounted` is decided once, when the disc is classified, and
/// never revisited. On I_AM_LEGEND that was wrong within seconds:
///
///     20:44:48Z  disc hold: holding disk4 — awaitingWork
///     20:44:48Z  disc hold: released disk4
///     20:45:05Z  disc hold: holding disk4 — awaitingWork
///     20:45:33Z  unmounted disc: label recovered from the scan — I_AM_LEGEND
///
/// …while `mount` said `/dev/disk4 on /Volumes/I_AM_LEGEND`. The volume was
/// there and the app had `isMounted == false` from a moment when it was not —
/// partly because the app's own DiskArbitration hold is what keeps a disc from
/// mounting, so the classification races the thing it is classifying.
///
/// The consequence was not cosmetic. Every tool got `/dev/rdisk4` for a disc
/// with a perfectly good `/Volumes/I_AM_LEGEND/VIDEO_TS`, which is why the menu
/// read failed on three discs in a session. #0206 taught `menudump` to read the
/// raw device, and that is worth having for a disc that genuinely never mounts
/// (a locked screen, #0152) — but it was fixing the symptom. A disc that *is*
/// mounted should be read through its filesystem, which is the path every tool
/// handles best and the only one that needs no libdvdread at all.
///
/// So the mount state is a question asked at the point of use rather than a
/// fact carried from insertion. The pure part is `choose`; the filesystem part
/// is one `FileManager` call the caller supplies, which keeps this testable
/// without a disc, a drive or a mount.
nonisolated enum DiscSource {

    /// The path to hand a tool, given what is on disk now.
    ///
    /// - Parameters:
    ///   - rawDevice: `DiscInsertion.mountURL` — either a `/Volumes` path or
    ///     `/dev/rdiskN`.
    ///   - label: the disc's recovered label, used to find its volume.
    ///   - mountedVolume: the volume for `label` if one exists *and* holds a
    ///     readable `VIDEO_TS`; `nil` otherwise. Supplied rather than probed so
    ///     the decision is a pure function of its inputs.
    ///
    /// A mounted volume wins whenever there is one. The raw device is the
    /// fallback, not the preference: it needs libdvdread, it is what #0206 had
    /// to teach the menu helper to read, and a Mac without that library gets
    /// nothing from it.
    static func choose(rawDevice: URL, mountedVolume: URL?) -> URL {
        mountedVolume ?? rawDevice
    }

    /// Whether `url` looks like a raw device rather than a mounted volume.
    ///
    /// Used to decide whether looking for a volume is worth doing at all: a
    /// disc already reporting a `/Volumes` path needs no second opinion.
    static func isRawDevice(_ url: URL) -> Bool {
        url.path.hasPrefix("/dev/")
    }

    /// The mounted volume for `label`, when it exists and has a `VIDEO_TS`.
    ///
    /// `VIDEO_TS` and not merely the directory: a volume that is mounting, or
    /// one whose name collides with something else under `/Volumes`, is not a
    /// disc to read. This is the same test `menudump` applies before it will
    /// claim a filesystem path, kept deliberately in step with it.
    static func mountedVolume(
        forLabel label: String,
        fileManager: FileManager = .default
    ) -> URL? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/", !trimmed.hasPrefix("/dev") else { return nil }
        let volume = URL(fileURLWithPath: "/Volumes").appendingPathComponent(trimmed)
        for shape in ["VIDEO_TS", "video_ts"] {
            let videoTS = volume.appendingPathComponent(shape)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: videoTS.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return volume
            }
        }
        return nil
    }

    /// The whole question, answered for a disc.
    ///
    /// Returns the disc's own `mountURL` untouched unless it is a raw device
    /// *and* a matching volume with a `VIDEO_TS` is on disk — so this can only
    /// ever turn an unreadable path into a readable one, never the reverse.
    static func current(
        mountURL: URL,
        label: String,
        fileManager: FileManager = .default
    ) -> URL {
        guard isRawDevice(mountURL) else { return mountURL }
        return choose(
            rawDevice: mountURL,
            mountedVolume: mountedVolume(forLabel: label, fileManager: fileManager))
    }
}
