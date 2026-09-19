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
}
