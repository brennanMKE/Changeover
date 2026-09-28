import Foundation

/// #0162 — everything one disc is going to produce, as one value.
///
/// The layer that was missing. A `Job` is one encode of one title into one
/// file, and that is correct — `DVDPipeline`, `EncodeController` and
/// `PlexOrganizer` are all right to be singular, and `JobController` is right
/// to run one job at a time. What nothing represented was the disc itself:
/// "these two films, in this order, and the disc stays in the drive until both
/// are done."
///
/// Without it, `RipFlowController` had to conflate *what the user picked* with
/// *what to rip* — #0160 mirrored the active feature into the singular
/// `search`/`selectedMovieID` so that `ripRequest`, the Confirm step and the
/// library check could stay unchanged. That works for naming films and does
/// not work for importing them: on the Uncle Buck / The Great Outdoors disc,
/// 2026-09-27, the user named both films and the app could still only ever rip
/// one, then ejected the disc with the second film still on it.
///
/// A plan is ordered, immutable in its membership, and records what happened
/// to each entry. It never runs anything: `RipFlowController` asks it what is
/// next and hands that to `JobController.start`, exactly as it does today for
/// a single film. That is what keeps this additive — nothing below the plan
/// learns that discs can hold more than one film.
nonisolated struct DiscRipPlan: Equatable, Sendable {

    /// One film this disc will produce.
    nonisolated struct Entry: Equatable, Sendable {
        /// The scanned `DiscTitle.index` this film is on.
        let feature: Int
        /// The film itself, already bound to the disc it was chosen for
        /// (#0034's `selectionDisc`), so a plan can never file one disc's
        /// film under another's name.
        let metadata: MovieMetadata
        var state: State

        init(feature: Int, metadata: MovieMetadata, state: State = .waiting) {
            self.feature = feature
            self.metadata = metadata
            self.state = state
        }
    }

    /// Where one entry stands. `skipped` is distinct from `failed` on purpose:
    /// a film already in Plex that the user chose not to replace is not an
    /// error, and a plan that treats it as one would keep a disc in the drive
    /// waiting for a retry nobody wants.
    nonisolated enum State: Equatable, Sendable {
        case waiting
        case running(JobID)
        case done(JobID)
        case failed(JobID)
        case skipped(reason: String)
    }

    /// In disc order, which is the order the table shows and therefore the
    /// order a person predicts.
    private(set) var entries: [Entry]

    /// The disc these entries were planned for. Every question the plan
    /// answers is about *this* disc; a different one invalidates all of it.
    let disc: DiscInsertion

    init(disc: DiscInsertion, entries: [Entry]) {
        self.disc = disc
        self.entries = entries.sorted { $0.feature < $1.feature }
    }

    // MARK: - What to do next

    /// The next film to rip, or `nil` when there is nothing left to start.
    ///
    /// `nil` while one is already running: the plan does not queue work into a
    /// controller that refuses re-entry, it simply has nothing to offer until
    /// the running entry settles.
    var next: Entry? {
        guard !isRunning else { return nil }
        return entries.first { $0.state == .waiting }
    }

    var isRunning: Bool {
        entries.contains { if case .running = $0.state { return true } else { return false } }
    }

    /// Every entry has reached an end state — the condition the disc may be
    /// ejected on. A plan with a failure is still finished: the disc is not
    /// held hostage to a retry the user has not asked for.
    var isFinished: Bool {
        !entries.isEmpty && entries.allSatisfy {
            switch $0.state {
            case .waiting, .running: return false
            case .done, .failed, .skipped: return true
            }
        }
    }

    /// Films named but not yet started. What the Ripping and Done steps say
    /// is still to come, so "put the disc back in" is never the message while
    /// the app intends to keep going on its own.
    var waiting: [Entry] { entries.filter { $0.state == .waiting } }

    var completed: [Entry] {
        entries.filter { if case .done = $0.state { return true } else { return false } }
    }

    // MARK: - Recording what happened

    mutating func markRunning(_ feature: Int, jobID: JobID) {
        update(feature) { $0.state = .running(jobID) }
    }

    /// Settles the entry that job belongs to. Keyed on the **job id**, not on
    /// the feature, because by the time an outcome arrives the user may have
    /// changed what is selected — the same reason `JobController` binds a
    /// job's log to the job rather than to the controller (#0042).
    mutating func settle(jobID: JobID, succeeded: Bool) {
        guard let index = entries.firstIndex(where: { $0.state == .running(jobID) }) else { return }
        entries[index].state = succeeded ? .done(jobID) : .failed(jobID)
    }

    /// Takes a film out of the plan without calling it a failure — the film is
    /// already in Plex and the user did not ask to replace it.
    mutating func skip(_ feature: Int, reason: String) {
        update(feature) { entry in
            guard entry.state == .waiting else { return }
            entry.state = .skipped(reason: reason)
        }
    }

    private mutating func update(_ feature: Int, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.feature == feature }) else { return }
        change(&entries[index])
    }

    // MARK: - Building one

    /// The plan for a disc, from the films the user named.
    ///
    /// `nil` when nothing is named — there is no such thing as an empty plan,
    /// and a caller holding `nil` is in exactly the state it was in before
    /// this type existed.
    static func make(disc: DiscInsertion, films: [(feature: Int, metadata: MovieMetadata)]) -> DiscRipPlan? {
        guard !films.isEmpty else { return nil }
        return DiscRipPlan(
            disc: disc,
            entries: films.map { Entry(feature: $0.feature, metadata: $0.metadata) })
    }
}
