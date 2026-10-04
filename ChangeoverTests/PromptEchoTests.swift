import Foundation
import Testing
@testable import Changeover

/// #0209 — the model must not answer with the question.
///
/// On a disc labelled NEXT, the evidence panel told the user: *"The menus
/// suggest bonus material called “The Making of Signs” — no title on this disc
/// runs that long."* Nothing on that disc says Signs. Four more claims came
/// with it: "Behind the Scenes", "A Concert", "A Retrospective" and "LOOKING
/// FOR SIGNS".
///
/// All five are `DiscInterrogation`'s own prompt read back. Two were the format
/// examples (`The Making of Signs (58:54)`, `looking for Signs (6:11)`) and the
/// other three were the category list — "a making-of documentary, a
/// behind-the-scenes film, a concert, a retrospective". A small on-device model
/// asked to name things, on a disc that offered none of that kind, named the
/// things it had just been shown.
///
/// It was first read as stale state from an earlier disc leaking through. It
/// was not: `RipFlowController` clears `discUnderstanding` on every disc change
/// and this appeared on a fresh launch. Chasing the cache would have found
/// nothing, which is why the fix is where the words actually came from.
///
/// This matters out of proportion to its size. The evidence panel is what a
/// person consults when a wrong film gets filed, and it was stating, in the
/// app's own confident voice, a fact about a disc that was never in the drive.
struct PromptEchoTests {

    /// NEXT's real menu text, from joe's `menus/lines.json`.
    private static let nextDisc = DiscEvidence(
        volumeName: "NEXT",
        menuPages: [[
            "MAKING THE BEST NEXT THING",
            "VISUALIZING THE NEXT MOVE",
            "THE NEXT \"GRAND IDEA\"",
            "TWO MINUTES IN THE FUTURE WITH JESSICA BIEL",
            "PREVIEWS",
        ]],
        titles: [
            DiscTitle(index: 1, durationSeconds: 5_820, chapterCount: 18,
                      sizeBytes: 0, outputFileName: nil),
            DiscTitle(index: 5, durationSeconds: 1_096, chapterCount: 1,
                      sizeBytes: 0, outputFileName: nil),
        ]
    )

    /// The exact five the user was shown, as `Claim`s.
    private static func claims(_ labels: [String]) -> [DiscInterrogation.Claim] {
        labels.map { DiscInterrogation.Claim(question: .bonusFeature, label: $0, seconds: nil) }
    }

    /// The bug, with the disc and the answers that produced it.
    @Test func noneOfTheEchoedClaimsSurvivesTheDiscsOwnMenus() {
        let echoed = Self.claims([
            "The Making of Signs", "Behind the Scenes", "A Concert",
            "A Retrospective", "LOOKING FOR SIGNS",
        ])
        let kept = DiscInterrogation.corroborated(echoed, by: Self.nextDisc)
        #expect(kept.isEmpty, "the disc's menus support none of these: \(kept.map { $0.label })")
    }

    /// And the disc's real bonus material is kept. A filter that dropped
    /// everything would "fix" this by making the feature useless.
    @Test func theDiscsOwnLabelsSurvive() {
        let real = Self.claims([
            "Making the Best Next Thing",
            "Visualizing the Next Move",
            "Two Minutes in the Future with Jessica Biel",
        ])
        let kept = DiscInterrogation.corroborated(real, by: Self.nextDisc)
        #expect(kept.count == real.count, "dropped a real label: \(kept.map { $0.label })")
    }

    /// OCR damage must not cost a real label. Vision mangles menu text as a
    /// matter of course — `MenuExtraLabels` exists because of it — so the
    /// check asks that most of a claim's words appear, not that the line
    /// matches.
    @Test func anOCRMangledLabelIsStillSupported() {
        let haystack = "makimg the best next thimg visualizing the next move"
        #expect(DiscInterrogation.isSupported("Making the Best Next Thing", by: haystack),
                "three of four words are present; a bad OCR pass must not drop a real label")
    }

    /// One shared word is a coincidence, not corroboration. "The Making of
    /// Signs" shares only "making" with this disc, and that is exactly how it
    /// got on screen.
    @Test func oneSharedWordIsNotEnough() {
        let haystack = "making the best next thing"
        #expect(!DiscInterrogation.isSupported("The Making of Signs", by: haystack))
    }

    /// Short words are not counted on either side — "the", "of" and "a" are on
    /// every menu ever printed, and counting them would corroborate anything.
    ///
    /// So "The Making of Signs" is judged on `making` and `signs` alone, which
    /// is why sharing "making" with this disc is not enough.
    @Test func shortWordsAreNotCountedAsSupport() {
        #expect(!DiscInterrogation.isSupported("The Making of Signs",
                                               by: "making the best next thing"))
        #expect(!DiscInterrogation.isSupported("A Concert", by: "making the best next thing"))
        #expect(!DiscInterrogation.isSupported("A Retrospective", by: "making the best next thing"))
    }

    /// A menu whose OCR produced nothing substantial cannot corroborate *or*
    /// refute, so claims survive to the runtime cross-check — the same answer
    /// as a disc whose menus could not be read at all. Refusing everything here
    /// would turn an unreadable menu into a confident "this disc has no bonus
    /// material", which is the mistake this check exists to avoid making in the
    /// other direction.
    @Test func aMenuWithNothingSubstantialDefersRatherThanRefusing() {
        #expect(DiscInterrogation.isSupported("The Making of Signs", by: "the of a and"))
    }

    /// One edit, not two. "sign" and "sing" are one apart and unrelated, so
    /// short words are matched exactly however damaged they look.
    @Test func theEditToleranceIsBounded() {
        #expect(DiscInterrogation.isNearlyEqual("making", "makimg"))
        #expect(DiscInterrogation.isNearlyEqual("thing", "thimg"))
        #expect(!DiscInterrogation.isNearlyEqual("sign", "sing"), "too short to risk one edit")
        #expect(!DiscInterrogation.isNearlyEqual("signs", "songs"), "one edit, but still short")
        #expect(!DiscInterrogation.isNearlyEqual("concert", "retrospective"))
    }

    /// With no menu text at all there is nothing to check against, and the
    /// runtime cross-check downstream is the judge. Dropping every claim on a
    /// disc whose menus could not be read would turn an unreadable menu into a
    /// confident "this disc has no bonus material".
    @Test func aDiscWithNoMenuTextKeepsItsClaims() {
        let blind = DiscEvidence(volumeName: "NEXT", menuPages: [], titles: [])
        let some = Self.claims(["The Making of Signs"])
        #expect(DiscInterrogation.corroborated(some, by: blind).count == 1)
    }

    // MARK: - The second guard

    /// The placeholder is refused outright — a model can echo a placeholder as
    /// readily as a title, and angle brackets never appear in a menu label.
    @Test func thePlaceholderIsRefused() {
        #expect(DiscInterrogation.isPromptEcho("<the name the menu prints>"))
        #expect(DiscInterrogation.isPromptEcho("Making <something> of it"))
    }

    /// And nothing else is refused **by name**.
    ///
    /// An earlier cut of this fix kept a blocklist and put "The Making of
    /// Signs" on it, since that was the label echoed onto the NEXT disc. It
    /// broke the Signs disc, where those exact words are a real label its own
    /// menus print — `DiscInterrogationTests.signsIsUnderstoodEndToEnd` caught
    /// it. The echo is not a property of the words; it is a property of words
    /// that are not on the disc in hand, and `corroborated(_:by:)` is the only
    /// check that can tell the difference.
    @Test func noLabelIsRefusedByName() {
        for label in ["The Making of Signs", "looking for Signs", "A Concert",
                      "Behind the Scenes", "Making the Best Next Thing"] {
            #expect(!DiscInterrogation.isPromptEcho(label), "“\(label)” was refused by name")
        }
    }

    /// The same words, judged against two discs, get opposite answers — which
    /// is the whole idea.
    @Test func theSameLabelIsRightOnOneDiscAndWrongOnAnother() {
        let signs = DiscEvidence(
            volumeName: "SIGNS",
            menuPages: [["play", "bonus", "scenes"],
                        ["making Signs: a commentary", "looking for Signs (6:11)"]],
            titles: [])
        #expect(DiscInterrogation.isSupported(
            "The Making of Signs",
            by: signs.menuPages.flatMap { $0 }.joined(separator: " ")),
            "its own disc prints these words")
        #expect(!DiscInterrogation.isSupported(
            "The Making of Signs",
            by: Self.nextDisc.menuPages.flatMap { $0 }.joined(separator: " ")),
            "the NEXT disc does not")
    }

    /// The prompts no longer show a plausible title as an example at all,
    /// which is the fix the guards sit behind. Asserted against the real
    /// prompt text so a later edit cannot quietly reintroduce one.
    @Test(arguments: [DiscInterrogation.Question.bonusFeature, .extras])
    func noPromptOffersAPlausibleTitleAsItsExample(question: DiscInterrogation.Question) {
        let text = DiscInterrogation.instructions(for: question)
        #expect(!text.contains("The Making of Signs"))
        #expect(!text.contains("looking for Signs"))
        #expect(text.contains("<the name the menu prints>"),
                "the example should be an obvious placeholder")
    }
}
