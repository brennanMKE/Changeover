import Foundation
import Testing
@testable import Changeover

/// §7.4 — what the Upgrade button does and does not offer, and what the card
/// says while it decides. Both are pure functions, which since UI tests are
/// forbidden here is the only coverage that panel can have.
struct UpgradeGateTests {

    static let folder = "/Plex/Movies/Bloodsport (1988) {tmdb-10336}"
    static let file = "\(folder)/Bloodsport (1988).mp4"

    static var present: LibraryCheck {
        .done(tmdbID: "10336", .present([
            LibraryEntry(
                folderName: "Bloodsport (1988) {tmdb-10336}",
                folderPath: folder,
                files: [LibraryFile(name: "Bloodsport (1988).mp4", sizeBytes: 1_210_453_921, modified: nil)]
            ),
        ]))
    }

    static var acknowledgement: ReplaceAcknowledgement {
        ReplaceAcknowledgement(movieID: 10336, folderPath: folder)
    }

    static func proposal(upgradable: Bool) throws -> UpgradeProposal.Result {
        let inventory = try LibraryFileInventoryTests.inventory("bloodsport-library.json")
        let names = upgradable
            ? (1...23).map { MarkerRow(number: $0, name: "Name \($0)") }
            : []
        return UpgradeProposal.compare(
            filePath: file,
            inventory: inventory,
            offer: DiscUpgradeOffer(chapterNames: names)
        )
    }

    static func decide(
        isRunning: Bool = false,
        hasMovieSelected: Bool = true,
        ffmpegAvailable: Bool = true,
        libraryCheck: LibraryCheck? = nil,
        fileCheck: FileInventoryCheck? = nil,
        proposal: UpgradeProposal.Result?,
        replaceAcknowledgement: ReplaceAcknowledgement? = acknowledgement
    ) throws -> StartDecision {
        StartGate.decideUpgrade(
            isRunning: isRunning,
            hasMovieSelected: hasMovieSelected,
            ffmpegAvailable: ffmpegAvailable,
            libraryCheck: libraryCheck ?? present,
            fileCheck: fileCheck ?? .done(path: file, try LibraryFileInventoryTests.inventory("bloodsport-library.json")),
            proposal: proposal,
            replaceAcknowledgement: replaceAcknowledgement
        )
    }

    // MARK: - The gate

    @Test func anUpgradableFileWithAConfirmedReplacementIsReady() throws {
        #expect(try Self.decide(proposal: try Self.proposal(upgradable: true)) == .ready)
    }

    /// The upgrade overwrites the library file, so it needs exactly the
    /// confirmation a re-rip needs.
    @Test func theSameReplaceConfirmationIsRequired() throws {
        let decision = try Self.decide(
            proposal: try Self.proposal(upgradable: true),
            replaceAcknowledgement: nil
        )
        #expect(decision == .duplicateUnacknowledged)
    }

    @Test func aConfirmationForADifferentFolderDoesNotCount() throws {
        let decision = try Self.decide(
            proposal: try Self.proposal(upgradable: true),
            replaceAcknowledgement: ReplaceAcknowledgement(movieID: 10336, folderPath: "/Plex/Movies/Something Else")
        )
        #expect(decision == .duplicateUnacknowledged)
    }

    @Test func nothingToWriteIsNeverOfferedAsANoOp() throws {
        #expect(try Self.decide(proposal: try Self.proposal(upgradable: false)) == .upgradeNothingSelected)
        #expect(try Self.decide(proposal: nil) == .upgradeNothingSelected)
    }

    @Test func noDuplicateMeansThereIsNothingToUpgrade() throws {
        #expect(try Self.decide(libraryCheck: .done(tmdbID: "10336", .absent), proposal: nil) == .upgradeNothingSelected)
        #expect(try Self.decide(libraryCheck: .idle, proposal: nil) == .upgradeNothingSelected)
    }

    @Test func aCheckStillRunningSaysSoRatherThanRefusing() throws {
        #expect(try Self.decide(libraryCheck: .checking(tmdbID: "10336"), proposal: nil) == .libraryCheckInProgress)
        #expect(try Self.decide(fileCheck: .checking(path: Self.file), proposal: nil) == .fileCheckInProgress)
    }

    @Test func missingFFmpegDisablesTheUpgradeAndNamesTheInstallLine() throws {
        let decision = try Self.decide(ffmpegAvailable: false, proposal: try Self.proposal(upgradable: true))
        #expect(decision == .ffmpegMissing)
        #expect(decision.reason == "Upgrading needs ffmpeg — run brew install ffmpeg, then reopen this window.")
    }

    /// The point of `decideUpgrade` being its own function: a missing
    /// `ffmpeg` must never make a rip stricter.
    @Test func missingFFmpegNeverBlocksARip() {
        let decision = StartGate.decide(
            hasMovieSelected: true,
            isRunning: false,
            hasDisc: true,
            scanState: .idle,
            selectedTitleIndex: nil,
            selectedAudioTrackNumbers: [],
            runtimeLookup: .idle,
            mismatchAcknowledgement: nil
        )
        // Whatever it refuses for, it is never about ffmpeg.
        #expect(decision != .ffmpegMissing)
        #expect(StartDecision.allCases.filter { $0 == .ffmpegMissing }.count == 1)
    }

    @Test func aRunningJobBlocksTheUpgradeFirst() throws {
        #expect(try Self.decide(isRunning: true, proposal: try Self.proposal(upgradable: true)) == .jobRunning)
    }

    @Test func everyDecisionExceptReadyCarriesASentence() {
        for decision in StartDecision.allCases {
            if decision == .ready {
                #expect(decision.reason == nil)
            } else {
                #expect(decision.reason?.isEmpty == false, "\(decision)")
            }
        }
    }

    // MARK: - The card

    @Test func noDuplicateShowsNoCardAtAll() {
        #expect(UpgradePresentation.card(
            libraryCheck: .done(tmdbID: "10336", .absent),
            fileCheck: .idle,
            proposal: nil,
            menuState: .idle,
            ffmpegAvailable: true,
            decision: .upgradeNothingSelected
        ) == nil)
    }

    @Test func missingFFmpegSaysWhatToTypeAndThatRippingIsUnaffected() throws {
        let card = try #require(UpgradePresentation.card(
            libraryCheck: Self.present,
            fileCheck: .idle,
            proposal: nil,
            menuState: .idle,
            ffmpegAvailable: false,
            decision: .ffmpegMissing
        ))
        #expect(!card.offersUpgrade)
        #expect(card.footnote?.contains("brew install ffmpeg") == true)
        #expect(card.footnote?.contains("Ripping is unaffected.") == true)
    }

    @Test func theCardSaysItIsStillReadingTheFile() throws {
        let card = try #require(UpgradePresentation.card(
            libraryCheck: Self.present,
            fileCheck: .checking(path: Self.file),
            proposal: nil,
            menuState: .idle,
            ffmpegAvailable: true,
            decision: .fileCheckInProgress
        ))
        #expect(card.headline == "Reading what that file already has…")
        #expect(!card.offersUpgrade)
    }

    @Test func anUpgradableDiscOffersTheActionWithItsEstimate() throws {
        let card = try #require(UpgradePresentation.card(
            libraryCheck: Self.present,
            fileCheck: .done(path: Self.file, try LibraryFileInventoryTests.inventory("bloodsport-library.json")),
            proposal: try Self.proposal(upgradable: true),
            menuState: .idle,
            ffmpegAvailable: true,
            decision: .ready
        ))
        #expect(card.offersUpgrade)
        #expect(card.actionTitle == "Upgrade metadata (remux, ~2 min)")
        #expect(card.disabledReason == nil)
        #expect(card.rows.contains { $0.verdict == .upgrade })
    }

    /// A menu read still in flight must not look like a disc that will never
    /// offer anything.
    @Test func aMenuReadStillRunningIsSaidOutLoud() throws {
        let card = try #require(UpgradePresentation.card(
            libraryCheck: Self.present,
            fileCheck: .done(path: Self.file, try LibraryFileInventoryTests.inventory("bloodsport-library.json")),
            proposal: try Self.proposal(upgradable: false),
            menuState: .reading,
            ffmpegAvailable: true,
            decision: .upgradeNothingSelected
        ))
        #expect(card.footnote == MenuStatusLine.readingCaption)
        #expect(!card.offersUpgrade)
    }

    @Test func theOverwriteTickIsOnlyShownWhenItWouldChangeSomething() throws {
        let named = LibraryFileInventory(
            durationMS: 3000,
            audio: [AudioSummary(track: 0, codec: "aac", channels: 2, language: "eng", title: "English")],
            subtitleCount: 1,
            chapters: (0..<3).map { ChapterSummary(startMS: $0 * 1000, endMS: ($0 + 1) * 1000, title: "Real \($0)") }
        )
        let proposal = UpgradeProposal.compare(
            filePath: Self.file,
            inventory: named,
            offer: DiscUpgradeOffer(chapterNames: (1...3).map { MarkerRow(number: $0, name: "Disc \($0)") })
        )
        let card = try #require(UpgradePresentation.card(
            libraryCheck: Self.present,
            fileCheck: .done(path: Self.file, named),
            proposal: proposal,
            menuState: .idle,
            ffmpegAvailable: true,
            decision: .upgradeNothingSelected
        ))
        #expect(card.offersOverwriteToggle)
        #expect(card.footnote?.contains(UpgradePresentation.overwriteToggleTitle) == true)
    }
    // MARK: - The plain register (docs/plain-language-ui.md §3.8)

    static func card(
        libraryCheck: LibraryCheck? = nil,
        fileCheck: FileInventoryCheck? = nil,
        proposal: UpgradeProposal.Result?,
        menuState: MenuState = .idle,
        ffmpegAvailable: Bool = true,
        decision: StartDecision = .ready
    ) throws -> UpgradePresentation.Card? {
        UpgradePresentation.card(
            libraryCheck: libraryCheck ?? present,
            fileCheck: fileCheck ?? .done(path: file, try LibraryFileInventoryTests.inventory("bloodsport-library.json")),
            proposal: proposal,
            menuState: menuState,
            ffmpegAvailable: ffmpegAvailable,
            decision: decision
        )
    }

    /// The offer: one sentence naming what the disc adds, and one button.
    /// The comparison card itself is the Details rendering.
    @Test func anUpgradableDiscOffersOneSentenceAndOneButton() throws {
        let proposal = try Self.proposal(upgradable: true)
        let card = try Self.card(proposal: proposal)
        let offer = try #require(UpgradePresentation.plainOffer(card: card, proposal: proposal))

        #expect(offer.kind == .offer)
        #expect(offer.actionTitle == "Improve the Existing Copy (~2 min)")
        #expect(offer.sentence.contains("23 chapter names"))
        #expect(offer.sentence.contains("about 2 minutes, nothing is re-encoded"))
        // "and", not a comma, because this one is a sentence.
        #expect(!offer.sentence.contains("remux"))
        #expect(PlainLanguage.violations(in: offer.sentence).isEmpty)
        // The verbatim action title is untouched on the Details card.
        #expect(card?.actionTitle == "Upgrade metadata (remux, ~2 min)")
    }

    /// No duplicate, no card, nothing to say.
    @Test func noDuplicateOffersNothingPlainEither() throws {
        let card = try Self.card(libraryCheck: .done(tmdbID: "10336", .absent), fileCheck: .idle, proposal: nil, decision: .upgradeNothingSelected)
        #expect(UpgradePresentation.plainOffer(card: card, proposal: nil) == nil)
    }

    /// Silence is reserved for the states that are not a statement about the
    /// disc at all: a check that could not run, or has not finished.
    @Test func aCheckThatCouldNotRunOrHasNotFinishedSaysNothingPlain() throws {
        let noFFmpeg = try Self.card(fileCheck: .idle, proposal: nil, ffmpegAvailable: false, decision: .ffmpegMissing)
        #expect(UpgradePresentation.plainOffer(card: noFFmpeg, proposal: nil) == nil)

        let reading = try Self.card(fileCheck: .checking(path: Self.file), proposal: nil, decision: .fileCheckInProgress)
        #expect(UpgradePresentation.plainOffer(card: reading, proposal: nil) == nil)

        let unreadable = try Self.card(
            fileCheck: .unavailable(path: Self.file, reason: "no such file"),
            proposal: nil,
            decision: .upgradeNothingSelected
        )
        #expect(UpgradePresentation.plainOffer(card: unreadable, proposal: nil) == nil)
    }

    /// The user's correction to the plan: when the app **could** have
    /// improved an existing copy and declined to, silence is wrong — a card
    /// that vanishes is indistinguishable from a feature that is broken. The
    /// precise reason ("20 chapters in the file, 21 names on the disc — not
    /// upgraded") stays exactly where it was, one disclosure away.
    @Test func aRefusalSaysSoPlainlyRatherThanVanishing() throws {
        let names = (1...21).map { MarkerRow(number: $0, name: "Name \($0)") }
        let inventory = try LibraryFileInventoryTests.inventory("oppenheimer-library.json")
        let proposal = UpgradeProposal.compare(
            filePath: Self.file,
            inventory: inventory,
            offer: DiscUpgradeOffer(chapterNames: names)
        )
        #expect(proposal.declinedSomething)

        let card = try Self.card(
            fileCheck: .done(path: Self.file, inventory),
            proposal: proposal,
            decision: .upgradeNothingSelected
        )
        let offer = try #require(UpgradePresentation.plainOffer(card: card, proposal: proposal))
        #expect(offer.kind == .declined)
        #expect(offer.sentence == "This copy can't be improved from this disc.")
        #expect(offer.actionTitle == nil)
        #expect(PlainLanguage.violations(in: offer.sentence).isEmpty)
        // The reason, verbatim, still on the Details card.
        #expect(card?.rows.contains { $0.verdict == .refused("20 chapters in the file, 21 names on the disc — not upgraded") } == true)
    }

    /// The other half of that distinction, and the case that stays silent:
    /// the file already has everything this disc offers, so nothing was
    /// declined and there is nothing to report. This is the **real**
    /// Oppenheimer disc, whose menus name no chapters at all.
    @Test func aFileThatAlreadyHasEverythingSaysNothingAtAll() throws {
        let inventory = try LibraryFileInventoryTests.inventory("oppenheimer-library.json")
        let proposal = UpgradeProposal.compare(
            filePath: Self.file,
            inventory: inventory,
            offer: try UpgradeProposalTests.offer(slug: "oppenheimer", chapterCount: 21)
        )
        #expect(!proposal.offersUpgrade)
        #expect(!proposal.declinedSomething, "nothing was refused — the disc had nothing to give")

        let card = try Self.card(
            fileCheck: .done(path: Self.file, inventory),
            proposal: proposal,
            decision: .upgradeNothingSelected
        )
        #expect(UpgradePresentation.plainOffer(card: card, proposal: proposal) == nil)
        // A subtitle a remux cannot add is what Replace is for, not
        // something Changeover declined — so it must not trip the refusal.
        #expect(card?.rows.contains { if case .needsRerip = $0.verdict { return true } else { return false } } == true)
    }

    /// The overwrite tick is an expert decision and the control that answers
    /// it lives on the Details card, so the plain register stays out of it.
    @Test func theOverwriteDecisionStaysOnTheDetailsCard() throws {
        let named = LibraryFileInventory(
            durationMS: 3000,
            audio: [AudioSummary(track: 0, codec: "aac", channels: 2, language: "eng", title: "English")],
            subtitleCount: 1,
            chapters: (0..<3).map { ChapterSummary(startMS: $0 * 1000, endMS: ($0 + 1) * 1000, title: "Real \($0)") }
        )
        let proposal = UpgradeProposal.compare(
            filePath: Self.file,
            inventory: named,
            offer: DiscUpgradeOffer(chapterNames: (1...3).map { MarkerRow(number: $0, name: "Disc \($0)") })
        )
        #expect(proposal.overwriteWouldHelp)
        let card = try Self.card(fileCheck: .done(path: Self.file, named), proposal: proposal, decision: .upgradeNothingSelected)
        #expect(UpgradePresentation.plainOffer(card: card, proposal: proposal) == nil)
        #expect(card?.offersOverwriteToggle == true)
    }

}
