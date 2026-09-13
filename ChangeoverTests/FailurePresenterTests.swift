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
}
