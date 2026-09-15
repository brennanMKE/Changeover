import Foundation

/// #0041 — a validated snapshot of one job's progress: which `JobPhase` it's
/// in, and (once terminal) the `JobOutcome` it settled into. A pure value
/// type with two mutators, both of which return a *new* value or `nil` —
/// never mutate in place and never crash on an illegal edge, so a caller
/// (`JobController.applyPhase`/`finish`) can always fall back to "log and
/// ignore" on `nil`.
///
/// The existing `JobOutcome`/`JobFailure`/`JobStage` (`JobOutcome.swift`,
/// #0007) are wire format and are deliberately untouched by this ticket —
/// `JobState` wraps a `JobOutcome` for the terminal case rather than
/// widening it, so nothing about the existing wire shape changes.
///
/// The invariant `outcome != nil ⇔ phase.isTerminal` (and, when terminal,
/// `phase == JobState.terminalPhase(for: outcome)`) is enforced structurally,
/// not asserted after the fact: `advancing(to:)` refuses a terminal target
/// (terminal phases only ever arrive with an outcome, via `finishing(with:)`),
/// `finishing(with:)` refuses to run from an already-terminal phase, and
/// decoding rejects any payload that breaks either rule — so there is no code
/// path, local or off the wire, that produces a terminal phase with no
/// outcome, a non-terminal phase carrying one, or a phase that contradicts
/// its outcome.
nonisolated struct JobState: Codable, Sendable, Equatable {
    private(set) var phase: JobPhase
    /// 0…1 within the current phase; `nil` when unknown. Always `nil` today
    /// — no progress parser exists yet for either `HandBrakeCLI` or
    /// `makemkvcon`'s output, so there is no public way to set it to
    /// anything else. Kept as a field now so a future progress parser is an
    /// additive change, not a wire-shape one.
    private(set) var progress: Double?
    /// Non-nil if and only if `phase.isTerminal` — see the type doc comment.
    private(set) var outcome: JobOutcome?

    /// Every job starts here — `.starting`, no progress, no outcome.
    static let initial = JobState(phase: .starting, progress: nil, outcome: nil)

    private init(phase: JobPhase, progress: Double?, outcome: JobOutcome?) {
        self.phase = phase
        self.progress = progress
        self.outcome = outcome
    }

    /// The terminal phase `outcome` means:
    /// - `.succeeded` → `.succeeded`;
    /// - `.failed` whose `reason` is `.cancelled` → `.cancelled`;
    /// - any other `.failed` → `.failed`.
    static func terminalPhase(for outcome: JobOutcome) -> JobPhase {
        switch outcome {
        case .succeeded:
            return .succeeded
        case .failed(let failure):
            return (failure.reason == .cancelled) ? .cancelled : .failed
        }
    }

    /// Moves to a non-terminal `phase` — the mid-job reports `DVDPipeline`
    /// makes as it crosses `.encoding`/`.fallback`/`.organizing`/`.extras`.
    ///
    /// Returns `nil`, leaving the caller to discard the attempt (this is a
    /// pure function — there is no `self` to leave "untouched" beyond simply
    /// not producing a new value), when: this state is already terminal;
    /// `phase` is itself terminal (a terminal phase must carry the
    /// `JobOutcome` that only `finishing(with:)` supplies, so reaching one
    /// through here would violate the invariant); or the edge isn't listed
    /// in `JobPhase.allowedTransitions`.
    func advancing(to phase: JobPhase) -> JobState? {
        guard !self.phase.isTerminal, !phase.isTerminal, self.phase.canTransition(to: phase) else {
            return nil
        }
        return JobState(phase: phase, progress: nil, outcome: nil)
    }

    /// Maps `outcome` onto a terminal phase (`terminalPhase(for:)`) and moves
    /// there — the single transition `JobController.finish` applies with the
    /// `JobOutcome` a job's `Runner` returned.
    ///
    /// The mapped target is then checked against `JobPhase.allowedTransitions`
    /// exactly as `advancing(to:)` does. So `.succeeded` is legal only from
    /// `.organizing` or `.extras` (the feature has to be in Plex first), and a
    /// `.failed(reason: .cancelled)` outcome arriving while `.organizing` or
    /// `.extras` is rejected, not silently reinterpreted as a plain failure.
    ///
    /// Returns `nil` when `self.phase` is already terminal, or when the
    /// mapped target isn't a legal edge from `self.phase`.
    func finishing(with outcome: JobOutcome) -> JobState? {
        guard !phase.isTerminal else { return nil }
        let target = Self.terminalPhase(for: outcome)
        guard phase.canTransition(to: target) else { return nil }
        return JobState(phase: target, progress: nil, outcome: outcome)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case phase, progress, outcome
    }

    /// Decodes and re-validates, the same stance `JobID`'s decoder takes: a
    /// synthesized decoder would accept `{"phase":"succeeded"}` with no
    /// outcome, or `"failed"` carrying a `.succeeded` outcome — states the
    /// public API can never produce, arriving from a Phase 4 peer.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let phase = try container.decode(JobPhase.self, forKey: .phase)
        let progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        let outcome = try container.decodeIfPresent(JobOutcome.self, forKey: .outcome)

        if let progress, !(0...1).contains(progress) {
            throw DecodingError.dataCorruptedError(
                forKey: .progress, in: container,
                debugDescription: "progress \(progress) is outside 0…1"
            )
        }
        switch (phase.isTerminal, outcome) {
        case (false, nil):
            break
        case (true, let outcome?) where Self.terminalPhase(for: outcome) == phase:
            break
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .outcome, in: container,
                debugDescription: "phase \(phase.rawValue) does not match outcome \(String(describing: outcome))"
            )
        }
        self.init(phase: phase, progress: progress, outcome: outcome)
    }
}
