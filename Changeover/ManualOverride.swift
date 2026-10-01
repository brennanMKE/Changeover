import Foundation

/// #0176 — the user saying what the disc is, and the app believing them.
///
/// Every fix for the last four days has been a better reading of the disc.
/// #0172 stopped a film being moved off the feature it had been placed on,
/// #0173 stopped a bonus documentary being offered as a second film, #0174
/// filed one as a bonus, #0175 made the app weigh several kinds of evidence
/// before answering. All of them improve the guess, and every one of them was
/// written because a particular disc had already cost the user an afternoon.
///
/// What none of them gives is a way to stop guessing. On 2026-09-30 the user
/// wrote: *"We also really need a Manual Override for a disc which this app
/// just cannot understand. Currently this current build gets stuck with this
/// disc."* Stuck is the right word: a misread disc produced a Choose step
/// asking for a film that is not there, a Continue button that would not
/// enable, and a Start gate refusing a title the user knew was correct —
/// three refusals, none of which the user could answer, because each of them
/// is the app disagreeing with them about a fact they can see and it cannot.
///
/// So this is the one statement in the app that outranks the app's own
/// arithmetic: *this disc holds this many films, and this title is that
/// film.* It is offered on the Choose step unconditionally — never only when
/// the app admits to being unsure, because the cases that cost the user days
/// were exactly the cases where it was sure and wrong.
///
/// What it deliberately does **not** override: anything protecting a file
/// that already exists. "Replace the Existing File" (#0143) and the disc
/// identity guard (#0034) are not inferences about the disc, they are the
/// last line in front of a forty-minute encode overwriting a good library
/// copy, and a person saying "there are two films on this disc" has said
/// nothing about either. What it does override is the runtime cross-check
/// (#0032) and the per-feature fit check (#0167), both of which exist only to
/// catch the app — or the user — pairing a film with the wrong title. Once
/// the user has taken charge of that pairing, those two become warnings: they
/// stay on screen, with their numbers, and they stop being gates. That is the
/// whole point of an override, and the reason it is a `Bool` reaching
/// `StartGate` rather than another acknowledgement keyed to one title and one
/// movie — keying it would rebuild the gate it exists to open.
///
/// Pure, `nonisolated`, and made of integers and one `DiscInsertion`, like
/// `FeatureSelection`, `StartGate` and `DiscPhase`, so the whole decision is
/// unit-testable with no view model, no disc and no view — the only coverage
/// available in this project, where UI tests are forbidden
/// (`docs/ui-test-crash-prevention.md`).
nonisolated struct ManualOverride: Equatable, Sendable {

    /// The disc this override was made for.
    ///
    /// Held so the value itself refuses to apply to another disc, rather than
    /// trusting the one caller that clears it. `SelectionReset` learned that
    /// the hard way in #0034: a statement made about disc A, left standing for
    /// disc B, filed B's encode under A's name and overwrote it. An override
    /// is a far stronger statement than a movie pick — it reassigns the
    /// disc's titles — so it gets the same treatment, in two independent
    /// places: `adopt(disc:)` here, and `RipFlowController`'s own wipe when a
    /// different disc goes in.
    private(set) var disc: DiscInsertion?

    /// How many films the user says this disc holds. `nil` — the default, and
    /// the state of almost every disc — means the app's own reading stands
    /// and nothing here is consulted.
    private(set) var filmCount: Int?

    /// Film position (1-based, exactly as the screen numbers them: "Movie 2
    /// of 3") → the disc title index the user says it is.
    ///
    /// Keyed by position rather than by title index because the question the
    /// panel asks is "which part of the disc is Movie 2", and the answer has
    /// to be able to be absent while the one above it is present.
    private(set) var titles: [Int: Int] = [:]

    /// The most films this override will accept on one disc.
    ///
    /// Not `DiscTitleHeuristic.maximumFeaturesPerDisc`, which is 4 and is
    /// right for the *heuristic*: that cap exists because the app is guessing
    /// from runtimes alone, and a disc yielding eight candidates has been
    /// misread (Adventureland's branching variants). A person holding the
    /// sleeve is not guessing. Eight is a bound on a stepper so a slipped
    /// click cannot ask for four hundred search boxes, not a judgement about
    /// what a disc can hold.
    static let maximumFilms = 8

    init(disc: DiscInsertion? = nil) {
        self.disc = disc
    }

    /// Whether the user has taken charge of this disc.
    ///
    /// True as soon as a film count is set, before every title has been
    /// named. That is deliberate: by then the person has already said the app
    /// is wrong about the disc, and the fit and runtime checks — which judge
    /// a pairing the app no longer owns — stop being gates from that moment.
    /// They keep saying what they say; they just cannot refuse any more.
    var isActive: Bool { filmCount != nil }

    /// The film positions to ask about, in screen order.
    var films: [Int] { filmCount.map { Array(1...$0) } ?? [] }

    func title(forFilm film: Int) -> Int? { titles[film] }

    /// What the override imposes, and what is still missing.
    ///
    /// A verdict rather than a `Bool` for the reason `StartDecision` is one
    /// (#0053): a panel that refuses to apply has to say which answer it is
    /// waiting for, or it is one more control that does nothing for reasons
    /// the user cannot see.
    nonisolated enum Readiness: Equatable, Sendable {
        /// No override — the app's reading stands.
        case off
        /// The user has asked to do this by hand, and the scan has not yet
        /// listed anything to choose from. Clears on its own.
        case noTitlesYet
        /// These film positions have no title against them (or one the disc
        /// no longer has).
        case needsTitles(films: [Int])
        /// Every film has a distinct title on this disc: these are the
        /// feature titles, in the order the user put them in.
        case ready(features: [Int])

        /// The titles to impose, or `nil` while the answer is incomplete.
        ///
        /// Incomplete means "nothing imposed", never "impose half of it": a
        /// half-answered override would reshape the Choose step between two
        /// clicks of one sentence being written.
        var features: [Int]? {
            if case .ready(let features) = self { return features }
            return nil
        }

        /// What the panel says about itself, in the plain register.
        var plain: String? {
            switch self {
            case .off:
                return nil
            case .noTitlesYet:
                return "Waiting for the disc to be read — the parts of the disc appear here."
            case .needsTitles(let films):
                let names = films.map { "Movie \($0)" }
                return "Say which part of the disc \(ManualOverride.list(names)) is."
            case .ready(let features):
                let count = features.count
                return count == 1
                    ? "Using your answer: one movie on this disc."
                    : "Using your answer: \(count) movies on this disc."
            }
        }
    }

    /// Judge the override against the titles the disc actually has.
    ///
    /// `available` is every scanned title index, not the ones the app thinks
    /// are features — the whole point is to reach past that judgement. A
    /// title the disc no longer has (a re-scan at a different `--minlength`,
    /// a different disc whose wipe somehow did not run) counts as no answer
    /// at all, which is #0034's rule applied to titles instead of films.
    func readiness(amongTitles available: [Int]) -> Readiness {
        guard filmCount != nil else { return .off }
        guard !available.isEmpty else { return .noTitlesYet }

        var seen: Set<Int> = []
        var features: [Int] = []
        var missing: [Int] = []
        for film in films {
            guard let index = titles[film], available.contains(index), !seen.contains(index) else {
                missing.append(film)
                continue
            }
            seen.insert(index)
            features.append(index)
        }
        guard missing.isEmpty else { return .needsTitles(films: missing) }
        return .ready(features: features)
    }

    /// Convenience for the one caller that only wants the imposed titles.
    func features(amongTitles available: [Int]) -> [Int]? {
        readiness(amongTitles: available).features
    }

    /// The single title a one-film override names, or `nil` for any other
    /// shape.
    ///
    /// Its own question because a one-film disc has no per-feature state at
    /// all (`FeatureSelection` is empty for it), so the title has to be
    /// settled on `JobController` directly — there is no named film to carry
    /// it there the way `applyActiveFeature` does on a multi-feature disc.
    var soleFeature: Int? {
        guard filmCount == 1 else { return nil }
        return titles[1]
    }

    // MARK: - Changing it

    /// Keep this override only for the disc it was made for.
    ///
    /// Same disc — including the same disc re-inserted, which `sameDisc`
    /// recognises by identity rather than by equality — and it stands
    /// untouched, so a re-scan, a recovered label (#0152) or a reconcile
    /// triggered by anything at all cannot wipe what the user said. Any other
    /// disc, or an empty drive, and it goes: a statement about one disc's
    /// titles is meaningless against another's.
    ///
    /// A disc with no resolvable identity re-reported as a fresh insertion
    /// clears the override, exactly as it clears the movie selection
    /// (`SelectionReset.sameDisc`). Failing that way is the safe direction:
    /// it asks the question again rather than silently ripping title 4 of the
    /// wrong disc.
    mutating func adopt(disc newDisc: DiscInsertion?) {
        if let current = disc, let newDisc, SelectionReset.sameDisc(current, newDisc) { return }
        if disc == nil, newDisc == nil { return }
        self = ManualOverride(disc: newDisc)
    }

    /// "This disc holds this many films" — the one action the ticket asks
    /// for. `nil` hands the disc back to the app.
    ///
    /// Clamped rather than refused: a stepper cannot produce anything else,
    /// and a remote client (#0149) sending nonsense should land on the nearest
    /// sane answer rather than on a silently ignored call.
    ///
    /// Reducing the count drops the answers above it. They were answers about
    /// films the user has just said do not exist.
    mutating func setFilmCount(_ count: Int?) {
        guard let count else {
            self = ManualOverride(disc: disc)
            return
        }
        let clamped = min(max(1, count), Self.maximumFilms)
        filmCount = clamped
        titles = titles.filter { $0.key <= clamped }
    }

    /// "Movie 2 is this title" — straight off the raw title table, with no
    /// inference anywhere between the row and this dictionary.
    ///
    /// One title belongs to one film, so naming a title that another film
    /// already holds **takes it from that film**, leaving it blank and
    /// unanswered.
    ///
    /// #0169 did the same thing to film-to-feature assignment and #0172
    /// reversed it, so the difference matters. There the two search blocks
    /// were not on screen together: moving a film silently blanked a feature
    /// the user could not see, and left its collapsed row still showing a
    /// tick. Here every film is one row of the same short list, the move is
    /// visible in the same glance as the click that caused it, and
    /// `readiness` immediately names the film left without an answer. The
    /// alternative — refusing the click — would be the app arguing with an
    /// override, which is the one thing this type exists to stop.
    mutating func assign(titleIndex: Int?, toFilm film: Int) {
        guard let filmCount, film >= 1, film <= filmCount else { return }
        guard let titleIndex else {
            titles[film] = nil
            return
        }
        for (other, index) in titles where other != film && index == titleIndex {
            titles[other] = nil
        }
        titles[film] = titleIndex
    }

    /// "Let the app decide again."
    ///
    /// Keeps the disc, so the next override made for the same disc is not
    /// immediately adopted away by a reconcile.
    mutating func clear() {
        self = ManualOverride(disc: disc)
    }

    // MARK: - What the panel says

    /// One row of the raw title table, as the override panel lists it:
    /// `Title 4 · 1:25:22 · 17 chapters · 6.1 GB · 16:9`.
    ///
    /// The detail register, on purpose, and the one place in the app where
    /// that is the right register by default (`docs/plain-language-ui.md`
    /// §3): the user has asked to work in the disc's own vocabulary, and
    /// hiding the title index behind a disclosure would hide the very number
    /// they are choosing. Everywhere else — the Choose step's blocks, the
    /// confirmation row — keeps saying "the movie" and "1h 25m", because
    /// there the numbers are the app's business.
    ///
    /// The aspect is included because it is the field that tells a flipper
    /// disc's two transfers apart (#0157's `widescreenPreferred`), and a
    /// person overriding such a disc is choosing between two rows that agree
    /// on every other column.
    static func titleLabel(_ title: DiscTitle) -> String {
        var label = DiscTitleFormatting.confirmationDetail(index: title.index, title: title)
        if let aspect = aspectLabel(title.displayAspect) {
            label += " · \(aspect)"
        }
        return label
    }

    /// "16:9" or "4:3" — the two values a DVD actually carries, split at
    /// `DiscTitleHeuristic.widescreenThreshold`, which sits in the empty gap
    /// between them. `nil` when the scan reported no aspect.
    static func aspectLabel(_ aspect: Double?) -> String? {
        guard let aspect else { return nil }
        return aspect >= DiscTitleHeuristic.widescreenThreshold ? "16:9" : "4:3"
    }

    /// What the app currently makes of the disc, stated before the user is
    /// asked to disagree with it.
    ///
    /// Shown in the panel's closed state. A person cannot correct a reading
    /// they have not been told about, and "this disc holds one film" was
    /// never written down anywhere — it was only implied by a screen that
    /// asked one question instead of two.
    /// Unwrapped before the switch rather than matched as an `Optional`:
    /// `Outcome` has a case called `.none` of its own (#0026's "no title
    /// looks like a feature"), and `case .none` against an `Outcome?` is the
    /// one pattern in this codebase that silently means the wrong thing.
    static func appReading(_ outcome: DiscTitleHeuristic.Outcome?) -> String {
        guard let outcome else { return "Changeover hasn't read this disc yet." }
        switch outcome {
        case .single:
            return "Changeover reads this disc as one movie."
        case .multipleFeatures(let indices):
            return "Changeover reads this disc as \(indices.count) movies."
        case .playAll:
            return "Changeover reads this disc as a TV disc, not a movie."
        case .noTitles:
            return "Changeover read nothing playable off this disc."
        case .none:
            return "Changeover can't tell which part of this disc is the movie."
        }
    }

    /// Whether the Choose step's Continue may be pressed, as a rule over
    /// three plain facts.
    ///
    /// Pulled out of `RipFlowController.mayContinueFromChoose` so the rule can
    /// be read and tested without a flow controller, a scan, a TMDB transport
    /// and a `.loaded` runtime lookup — the four things a misfit needs before
    /// it exists. The property keeps the job of gathering the facts; this
    /// keeps the judgement.
    ///
    /// The judgement itself: a disc with nothing to import cannot continue
    /// whatever anyone says, because there is no film to carry forward. A
    /// misfit stops it only while the app owns the pairing. Once the user does
    /// (#0176), the misfit is a sentence on the row and Continue works —
    /// which is the difference between a warning and the four days this
    /// ticket came out of.
    static func mayContinue(hasRunnableFilm: Bool, misfittingFeatures: Int, isOverridden: Bool) -> Bool {
        guard hasRunnableFilm else { return false }
        return isOverridden || misfittingFeatures == 0
    }

    /// What a runtime mismatch says once the user has overridden the disc.
    ///
    /// The numbers stay — `DiscTitleFormatting.runtimeVerdictWording` still
    /// prints the delta — because the check is often right and a person who
    /// has mis-typed a year should still see it. What changes is that it no
    /// longer refuses: #0032 made a mismatch a stop-and-ask on the grounds
    /// that ripping the wrong title wastes forty minutes, which is true, and
    /// the user is the one who decides whether it is wrong.
    static let mismatchWarning = Wording(
        plain: "You set this disc up by hand, so this is only a warning.",
        detail: "Manual override in effect — the runtime cross-check does not gate Start."
    )

    /// "Movie 2", "Movies 2 and 3", "Movies 1, 2 and 4" — the Oxford-less
    /// English the rest of the app's sentences use.
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}
