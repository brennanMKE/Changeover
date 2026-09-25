import Foundation

/// #0022 — the model for a scanned disc: the disc, its titles, and the
/// streams inside each title. Plain value types, `nonisolated` at the type
/// level so a `nonisolated` parser (#0023) or scanner (#0024) can build them
/// without touching the main actor — and so the Phase 4 move into the
/// `ChangeoverProtocol` package is a file drag rather than a semantic
/// change, because that package will not have this target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting.
///
/// Deliberately free of UI imports (`AppKit`/`SwiftUI`/`Observation`) and of
/// any notion of *selection* — what the user picked is job state
/// (#0027's `RipRequest`), not disc state, so a reconnecting Phase 4 client
/// can be re-sent a `DiscInfo` without carrying another client's choices.
/// These JSON shapes are wire format; additive optional fields only from
/// here on.

// MARK: - Disc

nonisolated struct DiscInfo: Codable, Hashable, Sendable {
    var volumeName: String
    var driveName: String
    var titles: [DiscTitle]
}

// MARK: - Title

nonisolated struct DiscTitle: Codable, Hashable, Sendable, Identifiable {
    /// What the phase's Role enum calls it. Leniently decoded: an unknown
    /// raw value from a newer host falls back to `.extra` rather than
    /// failing a whole disc decode on an older client (#0022's
    /// forward-compatibility decision).
    nonisolated enum Role: String, Codable, Sendable, CaseIterable {
        case mainFeature
        case extra
        case ignore

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Role(rawValue: raw) ?? .extra
        }
    }

    /// Index passed to `makemkvcon mkv disc:0 <index>` — the leading field
    /// of TINFO. Stored under this name, not `id`: the app already has an
    /// `id` that means the TMDB id, and in #0028 the wrong integer means
    /// ripping the wrong title.
    var index: Int
    var id: Int { index }

    var durationSeconds: Int
    var chapterCount: Int
    /// Explicit width — this crosses the wire in Phase 4.
    var sizeBytes: Int64
    /// MakeMKV attribute 27, e.g. "B1_t00.mkv". NOT unique across scans of
    /// the same disc at different `--minlength` values (#0028) — a hint, not
    /// an id. `nil` from a HandBrake scan, which reports no output filename.
    var outputFileName: String?
    /// Attribute 16. Always `nil` on DVDs — kept for Blu-ray later; nothing
    /// may be designed around it.
    var sourceFileName: String?
    var segmentCount: Int?
    var streams: [DiscStream]
    /// #0025's heuristic reads and writes this.
    var suggestedRole: Role

    /// Angles on this title (HandBrake `AngleCount`). `nil` = not reported.
    var angleCount: Int?

    /// Display aspect ratio — `(Width × PAR.Num) / (Height × PAR.Den)` from
    /// HandBrake's `Geometry`. About 1.78 for widescreen, about 1.33 for a
    /// 4:3 transfer. `nil` = not reported.
    ///
    /// The point of keeping it is flipper discs, which carry the same film
    /// twice: a widescreen transfer and a 4:3 pan-and-scan one, identical in
    /// runtime and in every other field the app records. Without this they
    /// are indistinguishable, and the app has to ask a person which of two
    /// identical-looking rows is the one they want.
    var displayAspect: Double?

    /// #0016 consumes exactly these two fields for the deinterlace decision.
    /// `nil` means the scan did not report them — `DeinterlaceDecision.decide`
    /// treats that as "no filter", the same as an ambiguous scan.
    var frameRate: Double?
    var interlaceDetected: Bool?

    var duration: Duration { .seconds(Double(durationSeconds)) }

    private enum CodingKeys: String, CodingKey {
        case index, durationSeconds, chapterCount, sizeBytes, outputFileName
        case sourceFileName, segmentCount, streams, suggestedRole
        case frameRate, interlaceDetected, angleCount, displayAspect
    }

    init(
        index: Int,
        durationSeconds: Int,
        chapterCount: Int,
        sizeBytes: Int64,
        outputFileName: String?,
        sourceFileName: String? = nil,
        segmentCount: Int? = nil,
        streams: [DiscStream] = [],
        suggestedRole: Role = .ignore,
        frameRate: Double? = nil,
        interlaceDetected: Bool? = nil,
        angleCount: Int? = nil,
        displayAspect: Double? = nil
    ) {
        self.index = index
        self.durationSeconds = durationSeconds
        self.chapterCount = chapterCount
        self.sizeBytes = sizeBytes
        self.outputFileName = outputFileName
        self.sourceFileName = sourceFileName
        self.segmentCount = segmentCount
        self.streams = streams
        self.suggestedRole = suggestedRole
        self.frameRate = frameRate
        self.interlaceDetected = interlaceDetected
        self.angleCount = angleCount
        self.displayAspect = displayAspect
    }

    /// Lenient decode: a payload from an older host without the #0016 fields
    /// decodes to `nil` (unknown), never fails.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        durationSeconds = try container.decode(Int.self, forKey: .durationSeconds)
        chapterCount = try container.decode(Int.self, forKey: .chapterCount)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        outputFileName = try container.decodeIfPresent(String.self, forKey: .outputFileName)
        sourceFileName = try container.decodeIfPresent(String.self, forKey: .sourceFileName)
        segmentCount = try container.decodeIfPresent(Int.self, forKey: .segmentCount)
        streams = try container.decodeIfPresent([DiscStream].self, forKey: .streams) ?? []
        suggestedRole = try container.decode(Role.self, forKey: .suggestedRole)
        frameRate = try container.decodeIfPresent(Double.self, forKey: .frameRate)
        interlaceDetected = try container.decodeIfPresent(Bool.self, forKey: .interlaceDetected)
        angleCount = try container.decodeIfPresent(Int.self, forKey: .angleCount)
        displayAspect = try container.decodeIfPresent(Double.self, forKey: .displayAspect)
    }
}

// MARK: - Stream

nonisolated struct DiscStream: Codable, Hashable, Sendable, Identifiable {
    /// Leniently decoded like `Role`: an unknown kind from a newer host
    /// becomes `.unknown` rather than failing the disc decode.
    nonisolated enum Kind: String, Codable, Sendable, CaseIterable {
        case video
        case audio
        case subtitle
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    var index: Int
    var id: Int { index }

    var kind: Kind
    /// e.g. "V_MPEG2", "A_AC3", "S_VOBSUB", "S_CC608/DVD".
    var codecId: String
    var codecShort: String?
    /// ISO 639-2. `nil` means UNTAGGED — never decode it to `""` and never
    /// default it to "eng": an untagged disc decoded as English is what
    /// produces a silent MP4 downstream (#0027).
    var languageCode: String?
    /// Localized display string — never branch on this.
    var languageName: String?
    /// Attribute 30 / HandBrake's stream label — for #0027's dedup and the UI.
    var displayName: String?
    /// Attribute 13, e.g. "448 Kb/s" — for #0027's dedup.
    var bitrate: String?
    /// The variant axis, distinct from language: HandBrake reports
    /// "English (Wide Screen)" and "English (Letterbox)" as separate streams
    /// (#0033). The parenthetical lives here, never folded into
    /// `languageCode`/`languageName`.
    var variant: String?
    var channelCount: Int?
    var isDefault: Bool

    /// Attribute 22, stored raw. Known bits: 1 and 2 = commentary,
    /// 4096 = forced. Storing the integer keeps the wire format stable while
    /// the interpretation evolves; at least one more flag
    /// (visually-impaired audio) is known to exist upstream.
    var flags: Int

    var isForced: Bool { flags & 4096 != 0 }
    /// "Some flag other than forced" rather than `flags == 1 || flags == 2`,
    /// so an unrecognized flag is surfaced as commentary rather than silently
    /// treated as ordinary audio. Honest about being incomplete: Super
    /// Troopers 2's commentary carries `flags == 0` and no metadata
    /// identifies it (#0027).
    var isCommentary: Bool { flags != 0 && !isForced }
    /// MakeMKV converts this to text; MP4 can carry it. See #0029.
    /// MakeMKV reports `"S_CC608/DVD"`; HandBrake's `SourceName` is the bare
    /// `"CC608"` with no `S_` prefix — match both (#0033).
    var isTextSubtitle: Bool { codecId.hasPrefix("S_CC608") || codecId.hasPrefix("CC608") }

    private enum CodingKeys: String, CodingKey {
        case index, kind, codecId, codecShort, languageCode, languageName
        case displayName, bitrate, variant, channelCount, isDefault, flags
    }

    init(
        index: Int,
        kind: Kind,
        codecId: String,
        codecShort: String? = nil,
        languageCode: String? = nil,
        languageName: String? = nil,
        displayName: String? = nil,
        bitrate: String? = nil,
        variant: String? = nil,
        channelCount: Int? = nil,
        isDefault: Bool = false,
        flags: Int = 0
    ) {
        self.index = index
        self.kind = kind
        self.codecId = codecId
        self.codecShort = codecShort
        self.languageCode = languageCode
        self.languageName = languageName
        self.displayName = displayName
        self.bitrate = bitrate
        self.variant = variant
        self.channelCount = channelCount
        self.isDefault = isDefault
        self.flags = flags
    }

    /// Lenient decode: a payload from an older host without `variant` (or
    /// with fewer fields) decodes with defaults, never fails.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        kind = try container.decode(Kind.self, forKey: .kind)
        codecId = try container.decode(String.self, forKey: .codecId)
        codecShort = try container.decodeIfPresent(String.self, forKey: .codecShort)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        languageName = try container.decodeIfPresent(String.self, forKey: .languageName)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        bitrate = try container.decodeIfPresent(String.self, forKey: .bitrate)
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
        channelCount = try container.decodeIfPresent(Int.self, forKey: .channelCount)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        flags = try container.decodeIfPresent(Int.self, forKey: .flags) ?? 0
    }
}
