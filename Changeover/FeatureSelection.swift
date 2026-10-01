import Foundation

/// #0160 — which film the user has named for each feature on a disc that
/// holds more than one.
///
/// #0157 taught the app to *recognise* such a disc
/// (`DiscTitleHeuristic.multipleFeatures`, measured on Get Hard / The
/// Campaign and on Uncle Buck / The Great Outdoors). Everything downstream of
/// the recognition was still singular — one search term, one
/// `selectedMovieID`, one `RipRequest` — so the Uncle Buck disc prefilled the
/// search box with the whole volume label, "Uncle Buck Great Outdoors", which
/// returns nothing on TMDB and reads as a broken app rather than as a
/// question.
///
/// This is the state that makes the question askable once per film: a title
/// index per feature, and the movie id the user chose for it. Nothing here
/// guesses — on a disc with several films the app knows *how many* and not
/// *which is which*, and choosing would be a guess dressed as an answer.
///
/// Pure, `nonisolated` and made of plain integers, like `SelectionReset` and
/// `StartGate`, so the whole decision is unit-testable with no view model, no
/// disc and no view — the only coverage available here, since UI tests are
/// forbidden in this project (`docs/ui-test-crash-prevention.md`).
nonisolated struct FeatureSelection: Equatable, Sendable {

    /// The feature titles this disc holds, in disc order — the order the
    /// table the user reads is in.
    ///
    /// **Empty on an ordinary single-feature disc**, which is by far the
    /// common case. Every question below answers "no" for it, which is what
    /// keeps the single-selection path exactly as it was.
    private(set) var features: [Int] = []

    /// The film named for each feature: disc title index → TMDB movie id.
    /// Only ever holds keys that are in `features`.
    private(set) var choices: [Int: Int] = [:]

    /// The feature Start will rip.
    ///
    /// One job at a time is still the rule — `DVDPipeline` encodes one title
    /// (#0014) and a `RipRequest` carries one `MovieMetadata` — so a
    /// multi-feature disc is ripped one film per pass. **This is the seam for
    /// a second job:** every feature the user has identified stays in
    /// `choices`, so a later ticket can start the next one without asking
    /// again (`waitingFeatures` is that list). Queueing is deliberately not
    /// built here.
    private(set) var active: Int?

    /// Whether this disc needs a film named per feature at all.
    var isMultiFeature: Bool { features.count >= 2 }

    /// How many features have a film against them.
    var chosenCount: Int { choices.count }

    /// The film named for one feature, if any.
    func movieID(for feature: Int) -> Int? { choices[feature] }

    // MARK: - What each feature IS (#0182)

    /// What one feature-length stretch of a disc actually is.
    ///
    /// Every multi-feature disc up to now was treated as a disc of films, and
    /// on a disc of films that is right: Get Hard / The Campaign is two
    /// features, two folders, two {tmdb-} tags. Signs is not. It is one
    /// 1:46:25 film and one 58:54 making-of reel, both clearing the 45-minute
    /// feature floor, and it was offered as a double feature — which is the
    /// correct reading of the runtimes and the wrong reading of the disc.
    /// Reported by the user 2026-10-01: "it could be a disc with 2 main
    /// features but it could be a movie and a long bonus feature. When it is a
    /// bonus feature it needs to be imported together with the main movie. The
    /// current workflow does not support doing this at all."
    ///
    /// #0173 took the arithmetic as far as arithmetic goes: a second feature is
    /// comparable in length to the first, so a shortest/longest ratio under two
    /// thirds is not a second feature, and Signs' 0.553 now reads as one film.
    /// That line is drawn deliberately low — its own comment records that a
    /// genuine 90-minute-plus-60-minute double feature is kept on the
    /// multi-feature side on purpose — so a making-of long enough to clear it
    /// still arrives as "Movie 2 of 2", and so does every disc the user puts on
    /// that path themselves with #0176's override. At that point the runtimes
    /// have said everything they can say and only the person holding the box
    /// knows the answer.
    ///
    /// So this is a question, asked on the Choose step, defaulting to `.film`
    /// so the disc of two films is untouched (the 24-in-26 rule that has
    /// governed every step of this work).
    ///
    /// **A bonus feature carries no TMDB id.** It is not a film and has no
    /// entry in a movie database; what it has is a name printed on the disc's
    /// own menu — "The Making of Signs" — and a film it belongs to. Those two
    /// facts are what `PlexExtra` has needed since #0174, and they are all
    /// this case holds.
    nonisolated enum Kind: Equatable, Sendable {
        /// Its own `Movies/Title (Year) {tmdb-ID}/` folder — today's behaviour
        /// and the default for every slot on every disc.
        case film
        /// Imported *with* `of`, into that film's folder, as a Plex extra:
        /// `Movies/<Film>/<Kind>/<label>.mp4`. `of` is another feature's disc
        /// title index; the subfolder is derived from `label` by
        /// `PlexExtra.kind(forLabel:)`, never stored here — one fact, one
        /// writer, and the name is the fact.
        case bonusFeature(of: Int, label: String)
    }

    /// The kind set for each feature. **Absent means `.film`**, so the
    /// ordinary disc of films stores nothing at all and a `FeatureSelection`
    /// that has never heard of this ticket behaves exactly as it did.
    private(set) var kinds: [Int: Kind] = [:]

    func kind(for feature: Int) -> Kind { kinds[feature] ?? .film }

    func isBonusFeature(_ feature: Int) -> Bool {
        if case .bonusFeature = kind(for: feature) { return true }
        return false
    }

    /// The slots that are films — the ones that get a folder of their own.
    var filmFeatures: [Int] { features.filter { !isBonusFeature($0) } }

    /// The films a bonus feature may be attached to.
    ///
    /// Deliberately `runnableFeatures` and not `filmFeatures`: a bonus feature
    /// is filed *inside* its film's folder, and a film that is unnamed has no
    /// folder name yet while a film that is skipped is not going to have a
    /// folder at all. Attaching to either would mean encoding an hour of video
    /// into a path that does not resolve — or, worse, resolving it under
    /// whatever film happened to be active, which is #0034's shape.
    var bonusTargets: [Int] { runnableFeatures }

    /// The film this bonus feature will actually be filed with, or `nil` when
    /// the target has gone away.
    ///
    /// Resolved on every read rather than cascaded on every change, so the
    /// answer cannot go stale: unname the film and the bonus feature's
    /// question reopens; name it again and the attachment comes back exactly
    /// as it was. The user's statement is kept, and only its *consequence*
    /// depends on the rest of the disc.
    func bonusTarget(for feature: Int) -> Int? {
        guard case .bonusFeature(let target, _) = kind(for: feature) else { return nil }
        return bonusTargets.contains(target) ? target : nil
    }

    /// The name the user gave this bonus feature, whatever state it is in.
    func bonusLabel(for feature: Int) -> String? {
        guard case .bonusFeature(_, let label) = kind(for: feature) else { return nil }
        return label
    }

    /// Whether the name typed for a bonus feature survives becoming a path
    /// component. `PlexExtra.sanitize("..")` is `""`, and a nameless file in a
    /// Plex extras folder is worse than no file: there is nothing for Plex to
    /// show a person (#0178's rule 2, applied one step earlier, where the user
    /// can still fix it).
    func hasUsableBonusLabel(_ feature: Int) -> Bool {
        guard let label = bonusLabel(for: feature) else { return false }
        return !PlexExtra.sanitize(label).isEmpty
    }

    /// One bonus feature that is going to be imported: which disc title, which
    /// film it goes with, and what it is called.
    ///
    /// The whole output of this ticket, as plain values — `RipFlowController`
    /// projects exactly this onto the extras machinery #0178 already built,
    /// and nothing downstream of it learns that a feature-length title can be
    /// a bonus feature.
    nonisolated struct BonusImport: Equatable, Sendable {
        /// The bonus feature's own disc title index.
        let feature: Int
        /// The feature index of the film it is filed with.
        let film: Int
        let label: String
    }

    /// Every bonus feature that will be imported, in disc order: marked as
    /// one, named, not excluded, and attached to a film that is going to run.
    var bonusImports: [BonusImport] {
        features.compactMap { feature in
            guard !skipped.contains(feature),
                  let film = bonusTarget(for: feature),
                  hasUsableBonusLabel(feature),
                  let label = bonusLabel(for: feature) else { return nil }
            return BonusImport(feature: feature, film: film, label: label)
        }
    }

    /// The bonus features that will be imported with one film, in disc order.
    func bonusFeatures(of film: Int) -> [Int] {
        bonusImports.filter { $0.film == film }.map(\.feature)
    }

    /// Bonus features the user has named with nowhere to put them: marked as a
    /// bonus feature, not excluded, and either unattached or attached to a film
    /// that is unnamed or skipped.
    ///
    /// What `StartGate` refuses on. A disc whose only marked-up slot is a bonus
    /// feature has nothing to import — there is no folder to import it into —
    /// and saying "name at least one of this disc's movies" is the true answer
    /// where `noFeatureChosen`'s wording ("this disc holds several feature
    /// films") would be a sentence about a disc the user has just told us this
    /// is not.
    var unattachedBonusFeatures: [Int] {
        features.filter {
            isBonusFeature($0) && !skipped.contains($0) && bonusTarget(for: $0) == nil
        }
    }

    /// Whether this slot's question has an answer. A film is answered by a
    /// film; a bonus feature by a name and somewhere to put it.
    func isAnswered(_ feature: Int) -> Bool {
        switch kind(for: feature) {
        case .film:
            return choices[feature] != nil
        case .bonusFeature:
            return bonusTarget(for: feature) != nil && hasUsableBonusLabel(feature)
        }
    }

    /// Whether the question *can* be answered as the disc stands. A film's
    /// always can — there is a search box and TMDB. A bonus feature's cannot
    /// until some film on the disc has been named for it to belong to.
    private func isAnswerable(_ feature: Int) -> Bool {
        switch kind(for: feature) {
        case .film: return true
        case .bonusFeature: return !bonusTargets.isEmpty
        }
    }

    /// The user says this slot is a film after all — the way back from every
    /// bonus-feature decision, and why the decision is safe to make.
    ///
    /// It does not restore a film that was named before the slot became a
    /// bonus feature: `markAsBonusFeature` dropped the TMDB id because a bonus
    /// feature does not have one, and resurrecting a film the user picked
    /// several clicks ago would be the app answering a question on their
    /// behalf. The slot returns to being asked about, which is where it was.
    mutating func markAsFilm(_ feature: Int) {
        guard features.contains(feature), isBonusFeature(feature) else { return }
        kinds[feature] = .film
        alreadyChosenElsewhere = nil
    }

    /// The user says this slot is a bonus feature of `film`.
    ///
    /// Refused — rather than coerced — in the three cases that are not
    /// statements about this disc: a slot or a target the scan does not have, a
    /// slot attached to itself, and a slot attached to another bonus feature.
    /// The last is the one worth naming: a bonus feature of a bonus feature has
    /// no film at the end of the chain, so it has no folder, and allowing it
    /// would mean every reader of `bonusTarget` had to walk a graph that can
    /// contain a cycle. One level deep is what Plex's extras folders are.
    mutating func markAsBonusFeature(of film: Int, label: String, for feature: Int) {
        guard features.contains(feature),
              features.contains(film),
              film != feature,
              !isBonusFeature(film) else { return }
        kinds[feature] = .bonusFeature(of: film, label: label)
        // A bonus feature has no TMDB film. Dropping the id here is what keeps
        // `runnableFeatures`, `plannedFilms` and `DiscRipPlan` singular about
        // what a film is, with no second test anywhere for "…but is it really
        // a film?" — the kind is asked once, here.
        choices.removeValue(forKey: feature)
        alreadyChosenElsewhere = nil
        if active == feature { active = lowestChosen }
    }

    /// Rename a bonus feature. A no-op on a slot that is not one, so the name
    /// and the kind cannot get out of step.
    mutating func setBonusLabel(_ label: String, for feature: Int) {
        guard case .bonusFeature(let film, _) = kind(for: feature) else { return }
        kinds[feature] = .bonusFeature(of: film, label: label)
    }

    /// Re-point a bonus feature at a different film on the same disc, keeping
    /// the name. Goes through `markAsBonusFeature` so the refusals above are
    /// stated in exactly one place.
    mutating func setBonusTarget(_ film: Int, for feature: Int) {
        guard case .bonusFeature(_, let label) = kind(for: feature) else { return }
        markAsBonusFeature(of: film, label: label, for: feature)
    }

    /// #0170 — what this step is doing about one feature right now.
    ///
    /// The Choose step asks one question at a time (#0169), and the view read
    /// that as "the first feature with no film gets the search box, everything
    /// else is settled". Everything else is not settled: on a two-film disc
    /// with nothing named, feature 2 was drawn as a finished row — a
    /// checkmark, a Change link and the placeholder name "Movie 2" where a
    /// film title belongs. Captured on joe 2026-09-29, with the Start gate
    /// simultaneously reporting `noFeatureChosen`, which is the screen and the
    /// gate disagreeing about the same disc for the fourth time.
    ///
    /// Four states, because there are four: the one being asked about, the
    /// ones already answered, the ones queued behind the question, and the
    /// ones the user has excluded.
    nonisolated enum Question: Equatable, Sendable {
        /// The single feature whose search box is open.
        case ask
        /// A film has been named for it.
        case named
        /// No film yet, and it is not this feature's turn.
        case waiting
        /// The user said not to import it, named or not.
        case excluded
    }

    /// The one feature the step is asking about: the first whose question has
    /// no answer and that the user has not excluded. `nil` when every feature
    /// is accounted for, which is exactly when Continue becomes the only thing
    /// left to do.
    ///
    /// #0182 — "has an answer" is no longer "has a film", because a slot the
    /// user has called a bonus feature is answered by a name and a film to
    /// attach to, not by a TMDB id (`isAnswered`).
    ///
    /// The two passes are for one ordering case the Signs disc can produce. A
    /// bonus-feature slot cannot be answered while the disc has no named film
    /// to attach it to, so if it comes *first* in disc order the step would
    /// open an editor with an empty "part of" list and no way forward. Asking
    /// the answerable question first costs one extra scan of a two- or
    /// three-element array and means the user is never shown a question the
    /// app has made unanswerable. The fallback keeps the old guarantee: while
    /// anything is unanswered, something is being asked.
    var featureBeingAsked: Int? {
        features.first { !isAnswered($0) && !skipped.contains($0) && isAnswerable($0) }
            ?? features.first { !isAnswered($0) && !skipped.contains($0) }
    }

    func question(for feature: Int) -> Question {
        guard features.contains(feature) else { return .waiting }
        if skipped.contains(feature) { return .excluded }
        if isAnswered(feature) { return .named }
        return feature == featureBeingAsked ? .ask : .waiting
    }

    /// The film Start will rip, if one has been named.
    var activeMovieID: Int? { active.flatMap { choices[$0] } }

    /// Features the user has already identified that this pass will *not*
    /// rip — what a queue would read next. Nothing consumes it yet; it exists
    /// so the state a second job needs is already being kept correctly rather
    /// than discovered to be missing later.
    var waitingFeatures: [Int] {
        features.filter { $0 != active && choices[$0] != nil }
    }

    /// What `StartGate.decide` needs to refuse with a reason that names what
    /// is missing.
    ///
    /// #0167 — counts the films that will actually RUN, not the ones merely
    /// named. A disc whose only named film the user has skipped is a disc with
    /// nothing to start, and Start must say so rather than offering to rip
    /// something that was explicitly excluded.
    func gateInput(importable: Int) -> FeatureChoices {
        FeatureChoices(featureCount: features.count,
                       chosenCount: runnableFeatures.count,
                       importableCount: importable,
                       // #0182 — so a disc whose only answered slot is a bonus
                       // feature is refused with the reason that is true of it.
                       unattachedBonusCount: unattachedBonusFeatures.count)
    }

    /// Kept for callers that do not know the library answers — every runnable
    /// film counts as importable, which is what a disc with no checks yet is.
    var gateInput: FeatureChoices { gateInput(importable: runnableFeatures.count) }

    /// The feature titles an outcome names, in disc order. `[]` for every
    /// other outcome — a single-feature disc has no per-feature state at all,
    /// and that is what this type's "empty" means.
    static func features(in outcome: DiscTitleHeuristic.Outcome?) -> [Int] {
        guard case .multipleFeatures(let indices) = outcome else { return [] }
        return indices
    }

    /// Adopt the features a scan just reported.
    ///
    /// A choice for a title the disc no longer has is not a choice: re-scan a
    /// disc, or swap one in whose features land on different indices, and the
    /// stale picks go. Same reasoning as #0034's `SelectionReset` — a film
    /// chosen against one thing must never be filed against another.
    mutating func setFeatures(_ indices: [Int]) {
        skipped = skipped.filter { indices.contains($0) }
        // A refusal belongs to the disc it was refused on.
        alreadyChosenElsewhere = nil
        guard indices != features else { return }
        features = indices
        choices = choices.filter { indices.contains($0.key) }
        // #0182 — and the same rule for what each feature *is*. A kind belongs
        // to the disc it was set on: a slot the scan no longer reports, and a
        // bonus feature whose film the scan no longer reports, are both answers
        // about something that is not in the drive. Dropped rather than
        // re-pointed, because "which film is this the making-of of?" is a
        // question only the person holding the box can answer.
        kinds = kinds.filter { entry in
            guard indices.contains(entry.key) else { return false }
            guard case .bonusFeature(let film, _) = entry.value else { return true }
            return indices.contains(film)
        }
        if let active, !indices.contains(active) { self.active = nil }
        if active == nil { active = lowestChosen }
    }

    /// Name a film for one feature, or clear it with `nil`.
    ///
    /// Choosing makes that feature the one Start rips: the click is the user
    /// saying "this one", and on a disc where nothing is preselected there is
    /// no other event that could mean it.
    mutating func choose(movieID: Int?, for feature: Int) {
        guard features.contains(feature) else { return }
        if let movieID {
            // #0169/#0172 — one film, one feature, and the pick is REFUSED
            // rather than moved.
            //
            // Two features on a disc are two different films, so the same film
            // cannot be both. #0169 enforced that by letting the newest pick
            // win and silently releasing the older feature. That turned out to
            // be the wrong half of the rule: on 2026-09-30 the app had
            // correctly placed The Campaign on title 4 and Get Hard on title
            // 5, the user re-searched title 4 and chose Get Hard, and the app
            // moved it — leaving title 4 holding a 100-minute film on an
            // 85-minute title, title 5 suddenly blank, and its search box
            // still showing Get Hard ticked. One click produced three wrong
            // things and reported none of them.
            //
            // Refusing says what is true: that film is already accounted for.
            // `alreadyChosenElsewhere` is what the view reads to explain it.
            // Nothing is destroyed, so the user's next click is a real choice
            // rather than an undo.
            if let other = choices.first(where: { $0.key != feature && $0.value == movieID })?.key {
                alreadyChosenElsewhere = Rejection(feature: feature, movieID: movieID, heldBy: other)
                return
            }
            alreadyChosenElsewhere = nil
            choices[feature] = movieID
            active = feature
        } else {
            alreadyChosenElsewhere = nil
            choices.removeValue(forKey: feature)
            // Clearing the film Start was going to rip falls back to another
            // one the user has already named, rather than to nothing: they
            // have said what that disc holds, and Start should not go dead
            // because they changed their mind about which to do first.
            if active == feature { active = lowestChosen }
        }
    }

    /// #0172 — the last pick refused because that film is on another feature.
    ///
    /// Cleared by the next successful choice, so it describes only what just
    /// happened. Held here rather than in the view because the view is not
    /// where this is decided, and because a refusal nobody can see is
    /// indistinguishable from a click that did nothing.
    nonisolated struct Rejection: Equatable, Sendable {
        /// The feature the user was trying to name.
        var feature: Int
        var movieID: Int
        /// The feature that already holds that film.
        var heldBy: Int
    }

    private(set) var alreadyChosenElsewhere: Rejection?

    /// Dismiss the refusal notice — the user has read it.
    mutating func acknowledgeRejection() { alreadyChosenElsewhere = nil }

    /// #0167 — features the user has said not to import.
    ///
    /// Distinct from "no film named": a film can be named, recognised as one
    /// already in Plex, and deliberately left out. Before this there was no
    /// way to say so — the only offer was "Replace the Existing File", and a
    /// film the user did not want blocked the whole disc, because `StartGate`
    /// judged it by whichever film was active.
    private(set) var skipped: Set<Int> = []

    func isSkipped(_ feature: Int) -> Bool { skipped.contains(feature) }

    /// Films that will actually be imported: a film, named, and not skipped.
    ///
    /// #0182 — the `isBonusFeature` test is defence in depth, not arithmetic:
    /// `markAsBonusFeature` already drops the TMDB id, so a bonus feature can
    /// never satisfy `choices[$0] != nil`. It is stated anyway because this
    /// list is what `DiscRipPlan` is built from and what `StartGate` counts,
    /// and a bonus feature reaching either would be the #0034 data-loss shape:
    /// a making-of filed into `Movies/` as though it were a film.
    var runnableFeatures: [Int] {
        features.filter { !isBonusFeature($0) && choices[$0] != nil && !skipped.contains($0) }
    }

    /// Whether anything at all will run — what Start should be judged on,
    /// rather than on the single mirrored selection.
    var hasRunnableFilm: Bool { !runnableFeatures.isEmpty }

    mutating func setSkipped(_ skip: Bool, for feature: Int) {
        guard features.contains(feature) else { return }
        if skip {
            skipped.insert(feature)
            // A skipped film must not stay the active one, or the disc is
            // still being judged by a film that is not going to run.
            if active == feature { active = runnableFeatures.first }
        } else {
            skipped.remove(feature)
            // #0182 — never a bonus feature. `active` is the film Start rips
            // and every consumer reads it as one; a bonus feature holds no
            // film at all, so putting one here would mirror "nothing" into the
            // singular selection and leave Start judging the disc by a slot
            // that is not a film.
            if active == nil, !isBonusFeature(feature) { active = feature }
        }
    }

    /// "Rip this one first" — an explicit switch between two films that have
    /// both been named. Ignored for a feature with no film against it, so the
    /// active feature always has one.
    mutating func makeActive(_ feature: Int) {
        guard choices[feature] != nil else { return }
        active = feature
    }

    private var lowestChosen: Int? {
        features.first { choices[$0] != nil }
    }
}
