import Foundation
import Testing
@testable import Changeover

/// #0196 — `changeoverctl select --extra-kind`, where it lands.
///
/// The window has no control for this and does not need one: the label comes off the
/// disc's own menu, and `PlexExtra.kind(forLabel:)`'s keyword rules were written
/// against the captured corpus of what menus actually print. An agent is in a
/// different position — it has read the OCR, the menu structure and the model's
/// answer — so it can name the folder outright.
///
/// The two things this file is here to hold:
///
/// 1. **The override is additive.** Every existing caller passes no kinds and gets
///    today's derivation, bit for bit. The window's running total, `JobController
///    .start` and ~15 construction sites across the extras tests all go through
///    `ExtrasPlan.make`, and this is the live extras path the user is importing
///    discs with right now.
/// 2. **An override can only ever be one of Plex's eight.** The parameter is typed
///    as the enum, so there is no spelling of a folder name that can reach the
///    pipeline — the string was already refused at the boundary
///    (`AgentSelectionPlan`).
@Suite struct ExtrasKindOverrideTests {

    /// Signs' bonus titles, trimmed to what these tests need. Durations matter only
    /// in that `ExtrasPlan.make` keeps the title; the filing is what is under test.
    private static func title(_ index: Int, _ seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 2,
                  sizeBytes: 0, outputFileName: nil)
    }

    private static var disc: DiscInfo {
        DiscInfo(volumeName: "Signs", driveName: "disk4", titles: [
            title(1, 6_385), title(8, 3_534), title(9, 375),
        ])
    }

    private func filing(of plan: ExtrasPlan, titleIndex: Int) -> ExtrasPlan.Filing? {
        plan.items.first { $0.titleIndex == titleIndex }?.filing
    }

    // MARK: - Nothing changes when nothing is overridden

    /// The derivation, untouched: "making" is a `behindTheScenes` keyword.
    @Test func withNoOverrideTheLabelStillDecidesTheFolder() {
        let plan = ExtrasPlan.make(
            featureIndex: 1,
            requested: [8],
            disc: Self.disc,
            labels: [8: "Making of Signs"]
        )
        #expect(filing(of: plan, titleIndex: 8) == .bonusFeature(kind: .behindTheScenes, label: "Making of Signs"))
    }

    /// #0192's rule: an extra with no usable name goes to `Other` beside the film,
    /// under the name `PlexExtra.fileName` generates. Unchanged.
    @Test func withNoOverrideAnUnnamedExtraStillGoesToOther() {
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [9], disc: Self.disc)
        #expect(filing(of: plan, titleIndex: 9) == .bonusFeature(kind: .other, label: ""))
    }

    // MARK: - The override

    /// The case the agent is for: the keyword rules read "making" and say
    /// `behindTheScenes`, and an agent that has read the disc's own bonus menu knows
    /// it is a featurette. The override wins.
    @Test func anOverrideBeatsTheDerivationFromTheLabel() {
        let plan = ExtrasPlan.make(
            featureIndex: 1,
            requested: [8],
            disc: Self.disc,
            labels: [8: "Making of Signs"],
            kinds: [8: .featurettes]
        )
        #expect(filing(of: plan, titleIndex: 8) == .bonusFeature(kind: .featurettes, label: "Making of Signs"))
    }

    /// Honoured even with no label: the extra goes to the named folder as
    /// `Bonus Feature - tNN.mp4`, which is honest about being title NN of the disc and
    /// is in the right place for Plex.
    @Test func anOverrideIsHonouredForAnExtraWithNoName() {
        let plan = ExtrasPlan.make(
            featureIndex: 1,
            requested: [9],
            disc: Self.disc,
            kinds: [9: .trailers]
        )
        #expect(filing(of: plan, titleIndex: 9) == .bonusFeature(kind: .trailers, label: ""))
        // And the filename is still the generated one, since a kind is not a name.
        #expect(
            PlexExtra.fileName(label: "", titleIndex: 9, extension: "mp4")
                == "Bonus Feature - t09.mp4"
        )
    }

    /// A label that sanitises to nothing is still not a label — the override changes
    /// only which folder, never whether the file gets a name of its own.
    @Test func anOverrideDoesNotRescueALabelThatSanitisesAway() {
        let plan = ExtrasPlan.make(
            featureIndex: 1,
            requested: [8],
            disc: Self.disc,
            labels: [8: ".."],
            kinds: [8: .interviews]
        )
        #expect(filing(of: plan, titleIndex: 8) == .bonusFeature(kind: .interviews, label: ""))
    }

    /// Keyed by title index like the labels are, so a kind can only ever attach to a
    /// title this plan already kept. It cannot pull a title in, and it cannot attach
    /// to the wrong one — #0028's rule applied to the third input.
    @Test func aKindForATitleThatIsNotRequestedIsIgnored() {
        let plan = ExtrasPlan.make(
            featureIndex: 1,
            requested: [8],
            disc: Self.disc,
            kinds: [9: .trailers, 99: .shorts]
        )
        #expect(plan.items.map(\.titleIndex) == [8])
        #expect(filing(of: plan, titleIndex: 8) == .bonusFeature(kind: .other, label: ""))
    }

    /// And it cannot make the feature into an extra of itself: `make` drops the
    /// feature index before anything else happens.
    @Test func aKindCannotDragTheFeatureIntoTheExtras() {
        let plan = ExtrasPlan.make(
            featureIndex: 1,
            requested: [1, 8],
            disc: Self.disc,
            kinds: [1: .featurettes]
        )
        #expect(plan.items.map(\.titleIndex) == [8])
    }

    @Test(arguments: PlexExtra.Kind.allCases)
    func everyKindCanBeNamedAndReachesTheDestination(_ kind: PlexExtra.Kind) {
        let plan = ExtrasPlan.make(
            featureIndex: 1,
            requested: [8],
            disc: Self.disc,
            labels: [8: "something"],
            kinds: [8: kind]
        )
        // The destination is what the pipeline hands `PlexOrganizer.move`, so it is
        // the value that actually decides the folder on disk.
        #expect(
            plan.items.first?.destination
                == .bonusFeature(titleIndex: 8, kind: kind, label: "something")
        )
    }

    // MARK: - The seam on its own

    @Test func theFilingHelperTakesAnOverride() {
        #expect(
            ExtrasPlan.filing(forLabel: "Deleted scene 4", kind: .scenes)
                == .bonusFeature(kind: .scenes, label: "Deleted scene 4")
        )
        // And without one, derives as it always did.
        #expect(
            ExtrasPlan.filing(forLabel: "Deleted scene 4")
                == .bonusFeature(kind: .deletedScenes, label: "Deleted scene 4")
        )
    }
}
