import Foundation
import Testing
@testable import Changeover
@testable import ChangeoverBridge

/// #0234 — the CLI must be able to import whatever the agent chose.
///
/// On REPO_MEN the agent selected the film and then could not import it: the
/// Unrated cut runs 119m against TMDB's 111m, `import` was refused
/// `runtimeMismatchUnconfirmed`, and there was no flag to offer. The window
/// clears that refusal with a "Rip anyway" button; the CLI had nothing.
///
/// The rule is one acknowledgement covering every refusal of that kind, not a
/// flag per gate — a flag per gate means the next confirm button added to the
/// window silently blocks the CLI again until somebody notices.
@Suite struct AgentConfirmationTests {

    /// The refusals `--confirm` is for.
    @Test func theconfirmButtonRefusalsAreClearable() {
        #expect(AgentConfirmation.canConfirm(.runtimeMismatchUnconfirmed))
        #expect(AgentConfirmation.canConfirm(.duplicateUnacknowledged))
    }

    /// An environment fact is not a decision anyone can confirm their way past,
    /// and an incomplete selection is work the agent must actually do.
    /// Confirming either would turn a clear refusal into a silent no-op.
    @Test func environmentAndSelectionRefusalsAreNotClearable() {
        for decision: StartDecision in [
            .noDisc, .discUnavailable, .jobRunning, .scanInProgress, .scanFailed,
            .noTitlesOnDisc, .noMovieSelected, .noFeatureChosen, .noTitleSelected,
            .noAudioTrackSelected, .runtimeLookupLoading, .libraryCheckInProgress,
            .ffmpegMissing, .everyFilmAlreadyInPlex,
        ] {
            #expect(!AgentConfirmation.canConfirm(decision),
                    "\(decision) is not something a button confirms")
        }
    }

    /// A permitting decision is never "cleared" — there is nothing to clear.
    @Test func thepermittingDecisionsAreNotClearable() {
        #expect(!AgentConfirmation.canConfirm(.ready))
        #expect(!AgentConfirmation.canConfirm(.readyForExtrasOnly))
    }

    /// Every clearable refusal says what it acknowledged, because the window
    /// asks for a reason and an agent overriding that belief should leave a
    /// record of which belief it overrode.
    @Test func everyclearableRefusalDescribesWhatWasConfirmed() {
        for decision in AgentConfirmation.clearable {
            #expect(AgentConfirmation.acknowledgementDescription(decision) != nil,
                    "\(decision) is clearable but says nothing about what was confirmed")
        }
    }

    /// And a refusal that is not clearable describes nothing, so the import
    /// result can never claim a confirmation it did not make.
    @Test func anunclearableRefusalDescribesNothing() {
        #expect(AgentConfirmation.acknowledgementDescription(.noDisc) == nil)
        #expect(AgentConfirmation.acknowledgementDescription(.ready) == nil)
    }

    /// Passing `--confirm` at a refusal it cannot clear must say so. An agent
    /// told only "Start is not available" cannot tell the flag was ignored from
    /// the flag being insufficient, and the obvious next move is to pass it
    /// again.
    @Test func anunconfirmableRefusalSaysTheFlagDidNotApply() {
        let detail = AgentConfirmation.unconfirmableDetail(.noTitleSelected,
                                                           reason: "Choose a title.")
        #expect(detail.hasPrefix("Choose a title."))
        #expect(detail.contains("--confirm does not apply"))
    }

    // MARK: - The CLI surface

    @Test func importAcceptsConfirm() throws {
        let parsed = CLIParse.parse(["import", "--disc", "ABC", "--confirm"])
        guard case .success(let invocation) = parsed,
              case .import(let options) = invocation.command
        else { Issue.record("import --confirm did not parse"); return }
        #expect(options.request.confirm)
        #expect(options.request.discInsertionID == "ABC")
    }

    /// Absent by default — confirming is always explicit.
    @Test func importWithoutConfirmDoesNotConfirm() throws {
        let parsed = CLIParse.parse(["import", "--disc", "ABC"])
        guard case .success(let invocation) = parsed,
              case .import(let options) = invocation.command
        else { Issue.record("import did not parse"); return }
        #expect(!options.request.confirm)
    }

    /// It belongs to `import` and nowhere else, so a stray `--confirm` is a
    /// usage error rather than silently ignored.
    @Test func confirmDoesNotApplyToOtherVerbs() {
        guard case .failure = CLIParse.parse(["eject", "--confirm"]) else {
            Issue.record("--confirm should not be accepted by eject"); return
        }
        guard case .failure = CLIParse.parse(["status", "--confirm"]) else {
            Issue.record("--confirm should not be accepted by status"); return
        }
    }
}
