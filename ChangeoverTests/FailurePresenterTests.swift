import Foundation
import Testing
@testable import Changeover

/// Covers #0009 §4 and §6 tests 16–18: `FailurePresenter` turns a
/// `JobFailure` into a headline and details a person reads, never
/// `String(describing:)`.
struct FailurePresenterTests {

    private static let sampleReasons: [FailureReason] = [
        .toolMissing(path: "/opt/homebrew/bin/HandBrakeCLI"),
        .toolLaunchFailed("no such file"),
        .toolIncompatible(detail: "unknown option (--no-such-flag)"),
        .toolExited(code: 1),
        .noTitlesProduced,
        .destinationUnwritable(path: "/Volumes/Plex/Movies"),
        .diskFull,
        .activationExpired,
        .discUnreadable,
        .cancelled,
        .unknown("something odd happened"),
    ]

    // MARK: - 16. Every reason gives a non-empty, non-leaky headline

    @Test func everyReasonGivesANonEmptyHeadlineWithNoLeakedSyntax() {
        for reason in Self.sampleReasons {
            // #0008: preflight joins the sweep — every reason a preflight
            // report can hold must still headline cleanly.
            for stage: JobStage in [.encode, .rip, .preflight] {
                let headline = FailurePresenter.headline(for: reason, stage: stage)
                #expect(!headline.isEmpty, "\(reason) at \(stage)")
                #expect(!headline.contains("(code:"), "\(reason) at \(stage): \(headline)")
                #expect(!headline.contains("_0"), "\(reason) at \(stage): \(headline)")
                #expect(!headline.contains("path:"), "\(reason) at \(stage): \(headline)")
            }
        }
    }

    // MARK: - 17. The five #0001 §7 item 6 messages

    @Test func handBrakeCLIMissingMessage() {
        let failure = JobFailure(stage: .encode, reason: .toolMissing(path: "/opt/homebrew/bin/HandBrakeCLI"))
        let message = FailurePresenter.message(for: failure)
        #expect(message.headline.contains("isn't installed"))
        #expect(message.details.contains { $0.contains("brew install handbrake") })
    }

    @Test func destinationUnwritableMessage() {
        let failure = JobFailure(stage: .encode, reason: .destinationUnwritable(path: "/Volumes/Plex/Movies"))
        let message = FailurePresenter.message(for: failure)
        #expect(message.headline.contains("can't write to /Volumes/Plex/Movies"))
        #expect(message.details.contains { $0.contains("connected") })
    }

    @Test func diskFullMessage() {
        let failure = JobFailure(stage: .encode, reason: .diskFull)
        let message = FailurePresenter.message(for: failure)
        #expect(message.headline.contains("full"))
        #expect(message.details.contains { $0.contains("Free up space") })
    }

    @Test func handBrakeFailedWithFallbackTakenMessage() {
        let failure = JobFailure(
            stage:    .encode,
            reason:   .discUnreadable,
            logTail:  [],
            fallback: .failed(stage: .rip, reason: .toolExited(code: 1), logTail: [])
        )
        let message = FailurePresenter.message(for: failure)
        #expect(message.details.contains { $0.contains("MakeMKV fallback was tried and also failed") })
    }

    /// #0046 review: a cancel during the fallback names no tool and is not
    /// reported as a second failure.
    @Test func aCancelDuringTheFallbackIsNotReportedAsASecondFailure() {
        let failure = JobFailure(
            stage:    .encode,
            reason:   .cancelled,
            logTail:  [],
            fallback: .failed(stage: .rip, reason: .cancelled, logTail: [])
        )
        let message = FailurePresenter.message(for: failure)
        #expect(message.headline == "The job was cancelled before it finished.")
        #expect(!message.details.contains { $0.contains("also failed") })
        #expect(message.details.contains { $0.contains("cancelled while the MakeMKV fallback was running") })
    }

    @Test func handBrakeFailedWithNoFallbackAvailableMessage() {
        let failure = JobFailure(
            stage:    .encode,
            reason:   .discUnreadable,
            logTail:  [],
            fallback: .unavailable(makemkvconPath: "/opt/homebrew/bin/makemkvcon")
        )
        let message = FailurePresenter.message(for: failure)
        #expect(message.details.contains { $0.contains("MakeMKV isn't installed") && $0.contains("no fallback was tried") })
    }

    // MARK: - 18. CSS variants and evidence quoting

    @Test func cssKeyFailureRefinesTheHeadlineAndMentionsTheRawDeviceFallbackWhenPresent() {
        let withoutContext = JobFailure(
            stage:   .encode,
            reason:  .discUnreadable,
            logTail: ["Error cracking CSS key"]
        )
        let message1 = FailurePresenter.message(for: withoutContext)
        #expect(message1.headline == "HandBrake couldn't unlock this disc's copy protection.")
        #expect(!message1.details.contains { $0.contains("libdvdcss can't open the drive directly") })

        let withContext = JobFailure(
            stage:   .encode,
            reason:  .discUnreadable,
            logTail: [
                "libdvdread: Attempting to retrieve all CSS keys",
                "Error cracking CSS key",
            ]
        )
        let message2 = FailurePresenter.message(for: withContext)
        #expect(message2.headline == "HandBrake couldn't unlock this disc's copy protection.")
        #expect(message2.details.contains { $0.contains("libdvdcss can't open the drive directly") })
    }

    @Test func cssUnavailableAddsAnInstallDetailWithoutChangingTheHeadline() {
        let failure = JobFailure(
            stage:   .encode,
            reason:  .discUnreadable,
            logTail: ["Encrypted DVD support unavailable (libdvdcss not found)"]
        )
        let message = FailurePresenter.message(for: failure)
        #expect(message.headline == "HandBrake couldn't read this disc.")
        #expect(message.details.contains { $0.contains("brew install libdvdcss") })
    }

    @Test func evidenceIsQuotedOnlyWhenTheMatchsReasonEqualsTheFailuresReason() {
        // A `.noTitlesProduced`-shaped line sitting in the tail of a
        // `.toolExited` failure must never be quoted as if it caused it.
        let failure = JobFailure(
            stage:   .encode,
            reason:  .toolExited(code: 1),
            logTail: ["No title found."]
        )
        let message = FailurePresenter.message(for: failure)
        #expect(!message.details.contains { $0.contains("HandBrake said") })
    }

    @Test func evidenceIsQuotedWhenItGenuinelyProducedTheReason() {
        let failure = JobFailure(
            stage:   .encode,
            reason:  .discUnreadable,
            logTail: ["libdvdread: Unrecoverable Read Error, aborting"]
        )
        let message = FailurePresenter.message(for: failure)
        #expect(message.details.contains { $0.contains("HandBrake said:") && $0.contains("Unrecoverable Read Error") })
    }

    @Test func fallbackFailedWithActivationExpiredYieldsTheMakeMKVKeySentence() {
        let failure = JobFailure(
            stage:    .encode,
            reason:   .discUnreadable,
            logTail:  [],
            fallback: .failed(stage: .rip, reason: .activationExpired, logTail: [])
        )
        let message = FailurePresenter.message(for: failure)
        #expect(message.details.contains { $0.contains("MakeMKV's registration key has expired") })
    }
    // MARK: - The plain register (docs/plain-language-ui.md §3.11)

    /// One plain headline per reason × stage, none of them empty, none of
    /// them leaking a path or an exit status. `headline(for:stage:)` and
    /// every `details` line above are untouched — they are what
    /// `bugReportText` pastes into a bug report.
    @Test func everyReasonAndStageHasAPlainHeadline() {
        for reason in Self.sampleReasons {
            for stage: JobStage in [.encode, .rip, .preflight, .organize] {
                let plain = FailurePresenter.plainHeadline(for: reason, stage: stage)
                #expect(!plain.isEmpty, "\(reason) at \(stage)")
                #expect(!plain.contains("/opt/homebrew"), "\(reason) at \(stage): \(plain)")
                #expect(!plain.contains("status"), "\(reason) at \(stage): \(plain)")
            }
        }
    }

    /// Preflight's two `.toolMissing` shapes stay distinct in the plain
    /// register too: "not set up yet" is a different thing to fix from
    /// "not installed".
    @Test func anUnsetPathAndAMissingToolReadDifferently() {
        #expect(FailurePresenter.plainHeadline(for: .toolMissing(path: ""), stage: .preflight)
                == "A program Changeover needs isn't set up yet. Open Settings to fix it.")
        #expect(FailurePresenter.plainHeadline(for: .toolMissing(path: "/opt/homebrew/bin/HandBrakeCLI"), stage: .preflight)
                == "A program Changeover needs isn't installed. Open Settings to fix it.")
    }

    /// The Plex media root itself gets the "is the drive connected" wording;
    /// its subfolders get the generic one — the same split `headline` makes.
    @Test func theDestinationSplitSurvivesIntoThePlainRegister() {
        #expect(FailurePresenter.plainHeadline(for: .destinationUnwritable(path: "/Volumes/Media/Plex Media"), stage: .preflight)
                == "Your Plex drive isn't connected.")
        #expect(FailurePresenter.plainHeadline(for: .destinationUnwritable(path: "/Volumes/Media/Plex Media/Movies"), stage: .preflight)
                == "Changeover can't save to your Plex folder. Check the drive is connected.")
    }

    /// `plainHeadline(for:)` applies the same CSS refinement `message(for:)`
    /// does, so the banner and the card describe the same failure.
    @Test func theCSSKeyRefinementReachesThePlainHeadlineToo() {
        let failure = JobFailure(
            stage: .encode,
            reason: .discUnreadable,
            logTail: [
                "libdvdread: Attempting to retrieve all CSS keys",
                "libdvdread: Error cracking CSS key for /VIDEO_TS/VTS_01_1.VOB",
            ]
        )
        #expect(FailurePresenter.message(for: failure).headline == "HandBrake couldn't unlock this disc's copy protection.")
        #expect(FailurePresenter.plainHeadline(for: failure) == "This disc's copy protection couldn't be unlocked.")
        // Without the evidence it stays the ordinary unreadable sentence.
        let plain = JobFailure(stage: .encode, reason: .discUnreadable)
        #expect(FailurePresenter.plainHeadline(for: plain) == "This disc couldn't be read. Clean it and try again.")
    }

    /// The one documented exemption from the forbidden-terms rule: the
    /// person has to open MakeMKV.app to fix this, so the name is the
    /// instruction.
    @Test func onlyTheExpiredKeyNamesATool() {
        let plain = FailurePresenter.plainHeadline(for: .activationExpired, stage: .rip)
        #expect(plain == "The backup disc reader (MakeMKV) needs a new registration key.")
        #expect(PlainLanguage.violations(in: plain) == ["MakeMKV"])
    }

}
