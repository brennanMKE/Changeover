import Foundation

/// #0023 — parses `HandBrakeCLI --scan --title 0 --min-duration 1 --json`
/// output into a `DiscInfo`.
///
/// Pure function: bytes in, `DiscInfo` out. No `Process`, no file system, no
/// main actor. Running the tool is #0024's job, and this split is what makes
/// the risky half testable without a disc.
///
/// The output is not a single JSON document: a `Version:` block, many
/// `Progress:` blocks, and libdvdnav log lines all arrive on stdout before
/// `JSON Title Set:` (verified against the real capture
/// `Fixtures/handbrake-scan/dragon-tattoo-title0-min1.json`). This parser
/// tolerates arbitrary non-JSON lines anywhere and locates the
/// `JSON Title Set:` section specifically.
///
/// Notable mappings onto the #0022 model:
/// - `FrameRate` is a rational `{Num, Den}` → stored as the quotient.
/// - Subtitle `Language` is `"English (Wide Screen) [VOBSUB]"` — the
///   parenthetical becomes `variant`, the bracketed codec tag is dropped,
///   and `languageCode` stays clean. The three are never folded together
///   (#0033).
/// - HandBrake reports explicit attribute booleans; they map into the raw
///   `flags` bitfield (Commentary → bit 1, Forced → bit 4096) so
///   `isForced`/`isCommentary` keep their #0022 meanings across backends.
///   `VisuallyImpaired` has no bit yet — not invented here.
/// - Video is title-level (`VideoCodec`, `Geometry`), not a stream entry —
///   no video `DiscStream` is synthesized.
/// - `sizeBytes`/`outputFileName`/`segmentCount`/`sourceFileName` are
///   MakeMKV-shaped fields this scan does not report; they stay `nil`/0
///   rather than being invented.
nonisolated enum HandBrakeScanParser {

    struct Output: Equatable {
        var disc: DiscInfo
        /// HandBrake's `MainFeature` — the title `Index` it considers the
        /// main feature, in the same numbering as `DiscTitle.index`. `nil`
        /// when the scan reported none.
        var mainFeatureIndex: Int?
        /// From the `Version:` block, e.g. "1.11.2" — diagnostic only.
        var versionString: String?
    }

    /// The marker that introduces the JSON payload on stdout.
    static let jsonMarker = "JSON Title Set:"

    nonisolated static func parse(
        _ text: String,
        volumeName: String,
        driveName: String
    ) -> Output {
        var titles: [DiscTitle] = []
        var mainFeature: Int?
        // The Version block precedes the JSON and is diagnostic on its own —
        // parse it even when the title set never arrived.
        let version = parseVersionBlock(text)

        if let markerRange = text.range(of: jsonMarker) {
            if let titleSet = parseTitleSet(text[markerRange.upperBound...]) {
                titles = Self.titles(fromJSON: titleSet)
                mainFeature = Self.mainFeature(fromJSON: titleSet)
            }
        }

        return Output(
            disc: DiscInfo(volumeName: volumeName, driveName: driveName, titles: titles),
            mainFeatureIndex: mainFeature,
            versionString: version
        )
    }

    // MARK: - Version block (before the JSON, best effort)

    /// Extracts the version from the `Version: { … }` block that precedes
    /// the title set. Brace-matched so interleaved noise cannot break it;
    /// any failure yields `nil` — diagnostic, never load-bearing.
    nonisolated static func parseVersionBlock(_ text: some StringProtocol) -> String? {
        guard let markerRange = text.range(of: "Version:") else { return nil }
        let rest = text[markerRange.upperBound...]
        guard let open = rest.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < rest.endIndex {
            if rest[index] == "{" { depth += 1 }
            if rest[index] == "}" {
                depth -= 1
                if depth == 0 {
                    let block = String(rest[open...index])
                    guard let data = block.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let version = object["Version"] as? [String: Any] else {
                        return nil
                    }
                    let major = number(version["Major"])?.intValue
                    let minor = number(version["Minor"])?.intValue
                    let point = number(version["Point"])?.intValue
                    switch (major, minor, point) {
                    case (.some(let m), .some(let n), .some(let p)):
                        return "\(m).\(n).\(p)"
                    case (.some(let m), .some(let n), _):
                        return "\(m).\(n)"
                    default:
                        return nil
                    }
                }
            }
            index = rest.index(after: index)
        }
        return nil
    }

    // MARK: - JSON extraction

    /// Parses the payload after the marker. The JSON document is extracted
    /// by brace-matching from its first `{`, so a straggler diagnostics line
    /// after the payload (stdout and stderr are merged in `ProcessRunner`)
    /// cannot corrupt it. `nil` when the section never arrived or is not
    /// decodable — a scan whose JSON is missing is a nil result, not a
    /// crash (#0024 classifies that).
    nonisolated static func parseTitleSet(_ text: some StringProtocol) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < trimmed.endIndex {
            if trimmed[index] == "{" { depth += 1 }
            if trimmed[index] == "}" {
                depth -= 1
                if depth == 0 {
                    let document = String(trimmed[open...index])
                    guard let data = document.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return nil
                    }
                    return object
                }
            }
            index = trimmed.index(after: index)
        }
        return nil
    }

    nonisolated static func mainFeature(fromJSON json: [String: Any]) -> Int? {
        number(json["MainFeature"])?.intValue
    }

    // MARK: - Title mapping

    nonisolated static func titles(fromJSON json: [String: Any]) -> [DiscTitle] {
        guard let list = json["TitleList"] as? [[String: Any]] else { return [] }
        return list.compactMap(title(fromJSON:))
    }

    private static func title(fromJSON json: [String: Any]) -> DiscTitle? {
        guard let index = number(json["Index"])?.intValue else { return nil }

        var durationSeconds = 0
        if let duration = json["Duration"] as? [String: Any] {
            let hours = number(duration["Hours"])?.intValue ?? 0
            let minutes = number(duration["Minutes"])?.intValue ?? 0
            let seconds = number(duration["Seconds"])?.intValue ?? 0
            durationSeconds = hours * 3600 + minutes * 60 + seconds
        }

        let chapters = (json["ChapterList"] as? [[String: Any]])?.count ?? 0

        var frameRate: Double?
        if let rate = json["FrameRate"] as? [String: Any],
           let num = number(rate["Num"])?.doubleValue,
           let den = number(rate["Den"])?.doubleValue, den != 0 {
            frameRate = num / den
        }

        let streams = audioStreams(from: json["AudioList"] as? [[String: Any]] ?? [])
            + subtitleStreams(from: json["SubtitleList"] as? [[String: Any]] ?? [])

        return DiscTitle(
            index: index,
            durationSeconds: durationSeconds,
            chapterCount: chapters,
            sizeBytes: 0, // HandBrake's scan reports no size; 0 = unknown
            outputFileName: nil,
            streams: streams,
            suggestedRole: .ignore, // #0025 decides
            frameRate: frameRate,
            interlaceDetected: number(json["InterlaceDetected"])?.boolValue,
            angleCount: number(json["AngleCount"])?.intValue
        )
    }

    // MARK: - Stream mapping

    nonisolated static func audioStreams(from list: [[String: Any]]) -> [DiscStream] {
        list.compactMap { entry in
            guard let json = entry as? [String: Any],
                  let track = number(json["TrackNumber"])?.intValue else { return nil }
            let attributes = json["Attributes"] as? [String: Any]
            return DiscStream(
                index: track,
                kind: .audio,
                codecId: json["CodecName"] as? String ?? "",
                languageCode: LanguageCode.normalize(json["LanguageCode"] as? String),
                languageName: json["Language"] as? String,
                displayName: json["Description"] as? String,
                bitrate: number(json["BitRate"]).map { String($0.intValue) },
                channelCount: number(json["ChannelCount"])?.intValue,
                isDefault: number(attributes?["Default"])?.boolValue ?? false,
                flags: attributeFlags(from: attributes, forcedKey: nil)
            )
        }
    }

    nonisolated static func subtitleStreams(from list: [[String: Any]]) -> [DiscStream] {
        list.compactMap { entry in
            guard let json = entry as? [String: Any],
                  let track = number(json["TrackNumber"])?.intValue else { return nil }
            let attributes = json["Attributes"] as? [String: Any]
            let language = json["Language"] as? String
            // The variant axis: the parenthetical in the display language
            // ("English (Wide Screen) [VOBSUB]"), with the bracketed codec
            // tag dropped. Falls back to the attribute flags when the
            // display string carries no parenthetical.
            let (clean, parenthetical) = splitVariant(from: language)
            let variant = parenthetical ?? variant(fromAttributes: attributes)
            return DiscStream(
                index: track,
                kind: .subtitle,
                codecId: json["SourceName"] as? String ?? "",
                languageCode: LanguageCode.normalize(json["LanguageCode"] as? String),
                languageName: clean,
                displayName: language,
                variant: variant,
                isDefault: number(attributes?["Default"])?.boolValue ?? false,
                flags: attributeFlags(from: attributes, forcedKey: "Forced")
            )
        }
    }

    /// Splits `"English (Wide Screen) [VOBSUB]"` into
    /// `("English", "Wide Screen")`. No parenthetical → the cleaned string
    /// and `nil`.
    nonisolated static func splitVariant(from language: String?) -> (clean: String?, variant: String?) {
        guard var clean = language else { return (nil, nil) }
        var variant: String?
        if let open = clean.firstIndex(of: "("), let close = clean.firstIndex(of: ")"), open < close {
            variant = String(clean[clean.index(after: open)..<close])
            clean.removeSubrange(open...close)
        }
        if let open = clean.firstIndex(of: "["), let close = clean.firstIndex(of: "]"), open < close {
            clean.removeSubrange(open...close)
        }
        return (clean.trimmingCharacters(in: .whitespaces), variant)
    }


    private static func variant(fromAttributes attributes: [String: Any]?) -> String? {
        guard let attributes else { return nil }
        if number(attributes["Wide"])?.boolValue == true { return "Wide Screen" }
        if number(attributes["Letterbox"])?.boolValue == true { return "Letterbox" }
        if number(attributes["PanScan"])?.boolValue == true { return "PanScan" }
        return nil
    }

    /// Maps HandBrake's explicit attribute booleans into the model's raw
    /// `flags` bitfield: Commentary → bit 1, Forced → bit 4096.
    private static func attributeFlags(from attributes: [String: Any]?, forcedKey: String?) -> Int {
        var flags = 0
        if number(attributes?["Commentary"])?.boolValue == true { flags |= 1 }
        if let forcedKey, number(attributes?[forcedKey])?.boolValue == true { flags |= 4096 }
        return flags
    }

    // MARK: - JSON helpers

    /// `JSONSerialization` bridges every JSON number to `NSNumber`; casting
    /// `Any` straight to `Int`/`Double`/`Bool` is brittle across number
    /// kinds, so everything numeric goes through here.
    private static func number(_ any: Any?) -> NSNumber? {
        any as? NSNumber
    }
}
