import Foundation

/// #0177 — turning what the disc said about itself into what the app does
/// about it.
///
/// `DiscInterrogation` answers "what is on this disc"; it deliberately stops
/// there. Deciding which of those answers may touch a search box, which may
/// tick an import, and which may only be shown to the user is a separate
/// judgement, and it is the judgement that has to be gettable at from a test —
/// UI tests are forbidden in this project, so a plain value in and a plain
/// value out is the only coverage available (`CLAUDE.md`).
///
/// ## Why this exists at all
///
/// #0171 is the reason. `MultiTitleInference` was written in #0159 with its
/// own green suite and called from nowhere; `RipFlowController` carried a doc
/// comment describing a menu rung that did not exist, and for the whole of
/// 2026-09-29 every automatic match in joe's `flow.log` was the one disc whose
/// label happens to spell both its films. A passing suite proved nothing,
/// because every test covered a piece and none covered whether a piece was
/// reachable. So this type is the reachable part, and
/// `DiscFindingsWiringTests` runs the chain the app actually takes.
///
/// ## The rule about unverified claims
///
/// A claim the disc could not corroborate never appears in `filmNamings`,
/// `bonusImports` or `extraLabels`. It appears in `unconfirmed`, which exists
/// to be shown. Measured on Signs, pressing the on-device model produced
/// DREAMSCAPE and DREAMLAND — confident, fluent, entirely invented — and the
/// only thing standing between that and a wrongly-named file in the library is
/// the refusal here to act on anything the disc's own clock did not agree
/// with.
nonisolated enum DiscFindings {

    // MARK: - What the app may do

    /// A film the disc both named and placed, ready to fill one feature's
    /// search box.
    ///
    /// Only ever a *verified* film finding, which means the model volunteered a
    /// runtime and the scan agreed with it. That is uncommon — the films
    /// question asks for names, not times — and it is correct that it is: a
    /// film named without a runtime is bound to its title by TMDB in
    /// `FeatureMatching`, which knows things this does not, and that path
    /// already runs as rungs 2 and 3 of `resolveEachFeature`.
    nonisolated struct FilmNaming: Equatable, Sendable {
        var feature: Int
        var label: String
        /// How far the claimed runtime sat from the scanned one.
        var offBySeconds: Int?
    }

    /// A long piece of bonus material to encode and file beside the film.
    nonisolated struct BonusImport: Equatable, Sendable {
        var titleIndex: Int
        var label: String
        /// Which of Plex's recognised extras subfolders it belongs in
        /// (`PlexExtra.Kind`), decided from the label the menu printed.
        var kind: PlexExtra.Kind
        var offBySeconds: Int?
    }

    /// Something the disc said that it could not prove.
    nonisolated struct Unconfirmed: Equatable, Sendable {
        var question: DiscInterrogation.Question
        var label: String
    }

    /// Everything one interrogation licenses, and everything it does not.
    nonisolated struct Plan: Equatable, Sendable {
        var filmNamings: [FilmNaming] = []
        var bonusImports: [BonusImport] = []
        /// Named short titles, by disc title index. Presentation: a row that
        /// reads "title 11" is a number, and "making Signs: a commentary" is
        /// an answer to the question the user is actually asking.
        var extraLabels: [Int: String] = [:]
        /// Claims to show, never to act on.
        var unconfirmed: [Unconfirmed] = []
        /// Titles the disc's own arithmetic nominates as bonus features
        /// (`BonusFeature.candidates`) and the menus did not name.
        ///
        /// Not imported. A title this app can measure but not name would land
        /// in the library as `Bonus Feature - t08`, which is worse than a
        /// ticked box the user can read the runtime off and decide about. It
        /// is carried so the log says what was there.
        var nominatedBonusTitles: [Int] = []

        var isEmpty: Bool {
            filmNamings.isEmpty && bonusImports.isEmpty
                && extraLabels.isEmpty && unconfirmed.isEmpty
        }

        /// One line for `flow.log`. #0171's lesson, kept: a rung that fires,
        /// refuses and leaves no trace cost a full day of debugging, so every
        /// decision this type makes is countable from the log alone.
        var diagnostic: String {
            "films=\(filmNamings.count) bonus=\(bonusImports.count) "
                + "extras=\(extraLabels.count) unconfirmed=\(unconfirmed.count) "
                + "nominated=\(nominatedBonusTitles.count)"
        }
    }

    // MARK: - The decision

    /// What may be done with one `Understanding`.
    ///
    /// - Parameters:
    ///   - understanding: the interrogation's result.
    ///   - features: this disc's feature title indices
    ///     (`FeatureSelection.features`) — empty on an ordinary one-film disc.
    ///   - named: features that already have a film against them. Never
    ///     renamed: the app's second opinion does not outrank its first, and a
    ///     box that changes under the user is the fault #0156 exists about.
    ///   - userTyped: features whose search box holds the user's own text
    ///     (`MovieSearchViewModel.queryIsUserEntered`). Never touched, at all,
    ///     for any reason.
    ///   - bonusCandidates: the title indices `BonusFeature.candidates`
    ///     nominated from the runtimes alone.
    ///
    /// A verified bonus finding is imported only when the disc's arithmetic
    /// nominates the same title. Two independent sources — the menu's printed
    /// runtime, which `DiscInterrogation.verify` matched, and the title's
    /// length against the film's, which `BonusFeature` compared — have to
    /// agree before a file is added to someone's library. That is the same
    /// standard `FeatureMatching` applies to a film's name, and it is why a
    /// model's answer is allowed to reach the filesystem at all.
    static func plan(
        from understanding: DiscInterrogation.Understanding,
        features: [Int] = [],
        named: Set<Int> = [],
        userTyped: Set<Int> = [],
        bonusCandidates: [Int] = []
    ) -> Plan {
        var plan = Plan()

        // Films: only onto a feature of this disc, only when that feature is
        // an open question.
        for finding in understanding.films {
            guard features.contains(finding.titleIndex),
                  !named.contains(finding.titleIndex),
                  !userTyped.contains(finding.titleIndex)
            else { continue }
            plan.filmNamings.append(FilmNaming(feature: finding.titleIndex,
                                               label: finding.label,
                                               offBySeconds: finding.offBySeconds))
        }

        // Bonus features: named by the menus AND nominated by the runtimes.
        let nominated = Set(bonusCandidates)
        for finding in understanding.bonusFeatures where nominated.contains(finding.titleIndex) {
            plan.bonusImports.append(BonusImport(
                titleIndex: finding.titleIndex,
                label: finding.label,
                kind: PlexExtra.kind(forLabel: finding.label),
                offBySeconds: finding.offBySeconds))
        }
        plan.bonusImports.sort { $0.titleIndex < $1.titleIndex }

        // A nominated title the menus did not name, or named without the disc
        // agreeing, is reported and left alone.
        let imported = Set(plan.bonusImports.map(\.titleIndex))
        plan.nominatedBonusTitles = bonusCandidates.filter { !imported.contains($0) }.sorted()

        // Extras: labels, which cost nothing and are wrong about nothing — the
        // title is on the disc either way, and this only decides what it is
        // called on screen.
        for finding in understanding.extras {
            plan.extraLabels[finding.titleIndex] = finding.label
        }

        plan.unconfirmed = understanding.unverified.map {
            Unconfirmed(question: $0.question, label: $0.label)
        }
        return plan
    }

    /// The unconfirmed claims as sentences, for the flow log and for whatever
    /// shows them.
    ///
    /// Phrased as the disc speaking and the app withholding judgement, because
    /// that is exactly the state of affairs: "the menus suggest" is true, and
    /// "this disc holds" would not be.
    static func unconfirmedLines(_ plan: Plan) -> [String] {
        plan.unconfirmed.map { claim in
            switch claim.question {
            case .films:
                return "The menus suggest a film called “\(claim.label)” — unconfirmed by the disc's runtimes"
            case .bonusFeature:
                return "The menus suggest bonus material called “\(claim.label)” — no title on this disc runs that long"
            case .extras:
                return "The menus suggest an extra called “\(claim.label)” — no title on this disc runs that long"
            }
        }
    }
}
