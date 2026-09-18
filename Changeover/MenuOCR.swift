import Foundation
#if canImport(Vision)
import Vision
import CoreGraphics
#endif

/// Menu intelligence, tier 2 — what the menu *says*, read off a still.
///
/// Two halves, deliberately split: a plain-value document
/// (`MenuOCRDocument`, the `menus/ocr.json` of
/// `docs/menu-intelligence.md` §8.3) that every resolver and every test
/// works from, and one Vision call that produces it. The resolvers never
/// touch Vision, so `ChapterNames`, `LanguageHints` and `MenuTitleGuess` are
/// pure functions over recorded text and can be pinned against a real disc's
/// captured output without a disc, a still, or a framework.
///
/// **Every observation is kept**, low-confidence ones included. The archive
/// exists to show what the engine actually does; a filter belongs in the
/// resolver where a test can see it.
nonisolated struct TextObservation: Codable, Equatable, Sendable {
    var text: String
    var confidence: Float
    /// Frame pixels, **top-left origin** — converted once from Vision's
    /// normalised bottom-left box so that text and button rectangles share
    /// one coordinate space.
    var rect: PixelRect

    init(text: String, confidence: Float, rect: PixelRect) {
        self.text = text
        self.confidence = confidence
        self.rect = rect
    }
}

/// `menus/ocr.json`, format `changeover-menu-ocr/1`.
nonisolated struct MenuOCRDocument: Codable, Equatable, Sendable {

    /// Exactly what produced the observations, so the same stills can be
    /// re-read later with a different setting and the two runs compared.
    nonisolated struct Engine: Codable, Equatable, Sendable {
        var framework: String
        var api: String
        var os: String?
        var level: String
        var languageCorrection: Bool
        var languages: [String]
        var customWords: Int
        var upscale: Int
        var minimumTextHeightFraction: Double
    }

    nonisolated struct Still: Codable, Equatable, Sendable {
        /// The menu PGC id (`vtsm-01-lu1-pgc3`) once the helper has named
        /// the stills; a capture made before the helper existed uses the
        /// still's own file stem and records that in `note`.
        var id: String
        var frame: MenuStructure.Frame?
        var note: String?
        var observations: [TextObservation]
    }

    var format: String
    var engine: Engine
    /// Anything a reader of the archive needs to know about how this
    /// capture was made — most usefully, when the still ids are not menu
    /// PGC ids because the capture predates `Tools/menudump`.
    var note: String?
    var stills: [Still]

    static func decode(_ data: Data) throws -> MenuOCRDocument {
        try JSONDecoder().decode(MenuOCRDocument.self, from: data)
    }

    func still(_ id: String) -> Still? { stills.first { $0.id == id } }
}

nonisolated enum MenuOCR {

    /// The settings §1.3 fixed for the first archive round.
    ///
    /// `usesLanguageCorrection` is **off**: correction did not rescue
    /// `Lanquages` on the Bloodsport run, and it is the mechanism most
    /// likely to "fix" a proper noun in a chapter name into something else.
    /// The document records the setting, so the archive can settle it later
    /// by re-reading the same stills both ways.
    nonisolated struct Settings: Equatable, Sendable {
        var languages: [String] = ["en", "fr", "es", "de", "it", "pt", "nl", "ja"]
        var usesLanguageCorrection = false
        var minimumTextHeightFraction: Double = 0.02
        var upscale = 1
        var customWords: [String] = MenuOCR.defaultCustomWords

        init() {}
    }

    /// The button lexicon, whole, plus the words a real run misread. The
    /// custom-word list takes precedence over Vision's dictionary, which is
    /// what a menu wants — these are labels, not prose.
    ///
    /// **Derived, never re-listed.** This used to spell out a second copy of
    /// the button vocabulary beside `MenuLexicon`'s, and the two had already
    /// drifted: Vision was being primed for "Continue" and "Main Menu" that
    /// the matcher did not know, so a button carrying one read cleanly and
    /// then meant nothing. One table, both uses.
    static let defaultCustomWords: [String] = MenuLexicon.customWords

#if canImport(Vision)
    /// Read one still. Off the main actor; the caller hops results back.
    ///
    /// Returns every observation Vision reported, in reading order, with its
    /// box already converted to top-left pixel coordinates on a frame of
    /// `frameWidth` × `frameHeight`.
    static func observations(
        in image: CGImage,
        frameWidth: Int,
        frameHeight: Int,
        settings: Settings = Settings()
    ) throws -> [TextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = settings.usesLanguageCorrection
        request.recognitionLanguages = settings.languages
        request.automaticallyDetectsLanguage = true
        request.customWords = settings.customWords
        // Vision spells §1.3's "minimum text height fraction" as
        // `minimumTextHeight`, a fraction of the image height.
        request.minimumTextHeight = Float(settings.minimumTextHeightFraction)

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            return TextObservation(
                text: best.string,
                confidence: best.confidence,
                rect: PixelRect(
                    visionBox: observation.boundingBox,
                    frameWidth: frameWidth,
                    frameHeight: frameHeight
                )
            )
        }
    }
#endif
}

#if canImport(CoreGraphics)
extension PixelRect {
    /// Vision's normalised, **bottom-left-origin** box → frame pixels with a
    /// top-left origin. Done once, here, so nothing downstream has to
    /// remember which way up the coordinates are.
    init(visionBox: CGRect, frameWidth: Int, frameHeight: Int) {
        let w = Double(frameWidth)
        let h = Double(frameHeight)
        let left = visionBox.minX * w
        let right = visionBox.maxX * w
        let top = (1 - visionBox.maxY) * h
        let bottom = (1 - visionBox.minY) * h
        self.init(
            minX: Int(left.rounded()),
            minY: Int(top.rounded()),
            maxX: Int(right.rounded()),
            maxY: Int(bottom.rounded())
        )
    }
}
#endif
