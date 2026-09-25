import Foundation

/// Reading a disc that never mounted.
///
/// #0073. With no volume there is no `/Volumes/NAME` to hand to HandBrake and
/// no volume label to identify the film by. Both come from the device instead.
nonisolated enum RawDiscSource {

    /// `disk4` → `/dev/rdisk4`.
    ///
    /// The *raw* device rather than the block device: libdvdread opens
    /// `/dev/rdiskN` for unbuffered reads, which is what HandBrake and
    /// `menudump` already use when given one. A name that already looks like
    /// a path is passed through, so a caller may hand over either.
    static func devicePath(bsdName: String) -> String? {
        let trimmed = bsdName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/dev/") { return trimmed }
        let digits = trimmed.dropFirst(4)
        guard trimmed.hasPrefix("disk"), !digits.isEmpty, digits.allSatisfy(\.isNumber)
        else { return nil }
        return "/dev/r" + trimmed
    }

    /// The disc's own label, read out of a HandBrake scan.
    ///
    /// Without a mount there is no volume name, and the label is the single
    /// most valuable identification signal there is — it carries the title on
    /// 18 of the 23 discs in the corpus. libdvdnav prints it during a scan:
    ///
    ///     libdvdnav: DVD Title: PUMP_UP_THE_VOLUME
    ///     libdvdnav: DVD Serial Number: 2c941367
    ///     libdvdnav: DVD Title (Alternative): PUMP_UP_THE_VOLUME
    ///
    /// The plain `DVD Title:` line is preferred and the `(Alternative)` one
    /// accepted as a fallback, since some discs carry only the latter.
    static func label(fromScanOutput output: String) -> String? {
        var alternative: String?
        for line in output.split(separator: "\n") {
            let text = String(line)
            // Checked first: "DVD Title (Alternative):" also contains the
            // substring "DVD Title", so the plain form has to be matched in a
            // way that cannot swallow it.
            if alternative == nil,
               let value = value(after: "DVD Title (Alternative):", in: text) {
                alternative = value
                continue
            }
            if let value = value(after: "DVD Title:", in: text) { return value }
        }
        return alternative
    }

    private static func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        // Discs with no label report a placeholder rather than nothing, and a
        // placeholder is worse than an absence: it looks like evidence.
        let rejected: Set<String> = ["", "unknown", "dvd_video", "dvdvideo", "dvdvolume"]
        guard !rejected.contains(value.lowercased()) else { return nil }
        return value
    }
}
