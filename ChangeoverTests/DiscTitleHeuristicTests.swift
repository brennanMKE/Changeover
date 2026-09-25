import Foundation
import Testing
@testable import Changeover

/// Covers #0025: HandBrake's MainFeature is the answer, the Play All guard
/// is the one check it cannot provide, and the negative result (summing all
/// non-feature titles) stays a test so a future simplification fails here
/// instead of shipping. Pure function — no disc, no process.
struct DiscTitleHeuristicTests {

    // MARK: - Helpers

    private static func title(_ index: Int, _ durationSeconds: Int, chapters: Int = 1) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: durationSeconds, chapterCount: chapters,
                  sizeBytes: 0, outputFileName: nil)
    }

    private static func disc(_ titles: [DiscTitle]) -> DiscInfo {
        DiscInfo(volumeName: "TEST", driveName: "disk6", titles: titles)
    }

    private static func fixturePath(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(relative)")
            .path
    }

    /// The real capture used by #0023's `HandBrakeScanParserTests`, scanned
    /// from the mounted Dragon Tattoo disc on joe: `MainFeature: 1` among 5
    /// titles, the other four all under 30 seconds. End-to-end proof that
    /// `classify` accepts what the actual scanner produces, not just
    /// synthetic fixtures shaped to the algorithm.
    private static func dragonTattooFixtureOutput() throws -> HandBrakeScanParser.Output {
        let text = try String(contentsOfFile: fixturePath("discs/dragon-tattoo/scan.json"),
                              encoding: .utf8)
        return HandBrakeScanParser.parse(text, volumeName: "DRAGON", driveName: "disk6")
    }

    /// Reads the real title durations and chapter counts from a committed
    /// `makemkvcon info` capture (TINFO attribute 9 = "h:mm:ss", 8 =
    /// chapters). Only what the guard reads; indices are MakeMKV's 0-based
    /// ones, so these captures exercise `playAllEpisodes` directly, not
    /// `classify` (which takes HandBrake's 1-based `MainFeature`).
    private static func makemkvTitles(_ name: String) throws -> [DiscTitle] {
        let text = try String(contentsOfFile: fixturePath("makemkvcon/\(name)"), encoding: .utf8)
        var durations: [Int: Int] = [:]
        var chapters: [Int: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("TINFO:") {
            let fields = line.dropFirst("TINFO:".count).split(separator: ",", maxSplits: 3)
            guard fields.count == 4, let index = Int(fields[0]) else { continue }
            let value = fields[3].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch fields[1] {
            case "9":
                let parts = value.split(separator: ":").compactMap { Int($0) }
                if parts.count == 3 { durations[index] = parts[0] * 3600 + parts[1] * 60 + parts[2] }
            case "8":
                chapters[index] = Int(value)
            default:
                break
            }
        }
        return durations.keys.sorted().map {
            Self.title($0, durations[$0]!, chapters: chapters[$0] ?? 0)
        }
    }

    /// A synthetic Play All disc shaped like Brooklyn Nine-Nine: a 10,398 s
    /// title (index 12, 33 chapters) plus eight ~21:40 episodes (titles
    /// 13–20) summing to exactly its duration, and two decoys. The episode
    /// durations are round stand-ins, not the disc's; the real ones
    /// (20:55–22:45) are checked in `realMakeMKVCorpusSeparatesTVDiscsFromMovies`.
    private static func brooklynNineNineDisc() -> DiscInfo {
        var titles = [Self.title(12, 10_398, chapters: 33)]
        let episodes: [Int] = [1299, 1300, 1300, 1300, 1300, 1300, 1299, 1300] // Σ = 10,398
        for (position, duration) in episodes.enumerated() {
            titles.append(Self.title(13 + position, duration, chapters: 4))
        }
        // Decoys that must never reach the guard pool.
        titles.append(Self.title(1, 12))
        titles.append(Self.title(2, 8))
        return disc(titles)
    }

    /// **Synthetic — not a real disc.** A trap for the "sum the whole pool
    /// instead of clustering" simplification, borrowing Super Troopers 2's
    /// feature length (5,955 s) and its 39:46 behind-the-scenes title.
    ///
    /// The real disc is much weaker evidence than this: it has only two
    /// non-feature titles of five minutes or more (1,170 s and 2,386 s), and
    /// its documented 0.905 sum-all ratio counts every sub-five-minute decoy
    /// too (see the corpus test). At the implemented 2% tolerance a sum-all
    /// regression would **not** misfire on the real disc, so this fixture is
    /// deliberately stronger than reality: its seven non-feature titles sum
    /// to 5,940 s — 99.7% of the feature, inside the 2% tolerance.
    ///
    /// What keeps it a movie: the largest 15% cluster is five titles
    /// (694, 650, 610, 570, 530 — 3,154 s, 53% of the feature). The
    /// cluster exists and has ≥ 3 members; it is the cluster's *total*
    /// failing the 2% duration match that saves it. Feature is HandBrake
    /// title index 1 (1-based).
    private static func sumAllTrapDisc() -> DiscInfo {
        Self.disc([
            Self.title(1, 5_955, chapters: 25),
            Self.title(30, 2_386),  // 39:46, as on the real disc
            Self.title(31, 694),
            Self.title(32, 650),
            Self.title(33, 610),
            Self.title(34, 570),
            Self.title(35, 530),
            Self.title(36, 500),
        ])
    }

    // MARK: - MainFeature is the answer

    @Test func mainFeatureIndexBecomesASingleAnswer() {
        let outcome = DiscTitleHeuristic.classify(Self.disc([Self.title(3, 6_645), Self.title(1, 600)]),
                                                  mainFeatureIndex: 3)
        #expect(outcome == .single(index: 3, source: .scanner))
    }

    /// #0056: absent, zero, negative or an unknown index are all "the
    /// scanner gave no answer" — one case. When *no* title clears the
    /// 45-minute fallback either, the result is still `.none`, exactly as
    /// before this ticket. (The case where the fallback *does* find exactly
    /// one candidate is covered by
    /// `noScannerAnswerFallsBackToLengthWhenExactlyOneTitleClearsTheThreshold`
    /// below — this disc's one title is kept under threshold on purpose so
    /// this test still exercises the "no answer at all" tail.)
    @Test func absentZeroNegativeAndUnknownMainFeatureAllAskTheUserWhenLengthFallsThroughToo() {
        let shortDisc = Self.disc([Self.title(1, 600)]) // 10 min — well under 45
        #expect(DiscTitleHeuristic.classify(shortDisc, mainFeatureIndex: nil) == .none)
        // Zero means the scan was wrong (single-title scan artefact), never
        // an answer.
        #expect(DiscTitleHeuristic.classify(shortDisc, mainFeatureIndex: 0) == .none)
        // #0056: a real disc (Hornets' Nest) reported -1 — HandBrake naming
        // no feature at all — which must be treated the same as absent/zero,
        // not fall through some other path.
        #expect(DiscTitleHeuristic.classify(shortDisc, mainFeatureIndex: -1) == .none)
        // An index the title list does not contain: ask, don't guess.
        #expect(DiscTitleHeuristic.classify(shortDisc, mainFeatureIndex: 9) == .none)
    }

    /// #0056's headline behavior, synthetic: no scanner answer, but exactly
    /// one title clears `featureMinimumSeconds` — promote it, and record
    /// that the choice came from length, not the scan.
    @Test func noScannerAnswerFallsBackToLengthWhenExactlyOneTitleClearsTheThreshold() {
        let disc = Self.disc([Self.title(1, 50 * 60), Self.title(2, 600)])
        let expected = DiscTitleHeuristic.Outcome.single(index: 1, source: .length)
        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: nil) == expected)
        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: 0) == expected)
        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: -1) == expected)
        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: 99) == expected)
    }

    /// The Plan's explicit "zero or two-or-more stays `.none`" guard on the
    /// fallback: two titles both clear 45 minutes and the scanner gave no
    /// answer — a theatrical/extended pair or a double feature, not a
    /// decision the threshold may make alone.
    @Test func twoTitlesAtOrAboveTheThresholdWithNoScannerAnswerStayNone() {
        let disc = Self.disc([Self.title(1, 50 * 60), Self.title(2, 60 * 60)])
        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: nil) == .none)
    }

    /// A TV-shaped disc — several episode-length titles, none individually
    /// reaching 45 minutes, and no concatenated Play All title for the guard
    /// to catch — must not be turned into a movie by the length fallback
    /// just because the scanner gave no answer. Zero candidates clear the
    /// threshold, so `.none` is the only correct answer here, but it is
    /// worth pinning: the fallback's job is to find a confident single
    /// answer, not to reach for the longest title on a disc that has none.
    @Test func tvShapedDiscWithNoScannerAnswerAndNoPlayAllTitleStaysNone() {
        var titles: [DiscTitle] = []
        for index in 1...8 { titles.append(Self.title(index, 22 * 60, chapters: 4)) }
        #expect(DiscTitleHeuristic.classify(Self.disc(titles), mainFeatureIndex: nil) == .none)
    }

    /// "Run the Play All guard on the fallback candidate exactly as on a
    /// scanner-provided one": no `MainFeature` at all on a Brooklyn
    /// Nine-Nine-shaped disc. The length fallback finds exactly one
    /// candidate (the 10,398 s concatenation; the eight ~21:40 episodes are
    /// each well under 45 minutes), and the guard must still refuse it.
    @Test func fallbackCandidateStillRunsThroughThePlayAllGuard() {
        let outcome = DiscTitleHeuristic.classify(Self.brooklynNineNineDisc(), mainFeatureIndex: nil)
        guard case .playAll(let index, let episodes) = outcome else {
            Issue.record("expected .playAll, got \(outcome)")
            return
        }
        #expect(index == 12)
        #expect(episodes == Array(13...20))
    }

    /// #0039 — the bug this ticket was filed against: a scan that read zero
    /// titles must classify as `.noTitles`, never `.none`. `.none` is a
    /// verdict about the disc's contents ("no title looks like a feature");
    /// `.noTitles` says the scan never looked at any contents at all. Every
    /// `mainFeatureIndex` shape is exercised to confirm the empty-title
    /// check wins regardless — an empty disc with a `mainFeatureIndex` at
    /// all would itself be a scan-shaped contradiction, but the guard must
    /// still refuse to fall through to `.none`'s wording.
    @Test func anEmptyTitleListIsNoTitlesNeverNone() {
        let empty = Self.disc([])
        #expect(DiscTitleHeuristic.classify(empty, mainFeatureIndex: nil) == .noTitles)
        #expect(DiscTitleHeuristic.classify(empty, mainFeatureIndex: 0) == .noTitles)
        #expect(DiscTitleHeuristic.classify(empty, mainFeatureIndex: 7) == .noTitles)
    }

    @Test func classificationIsDeterministicUnderReordering() {
        let playAll = Self.brooklynNineNineDisc().titles
        let expected = DiscTitleHeuristic.Outcome.playAll(index: 12, episodes: Array(13...20))
        #expect(DiscTitleHeuristic.classify(Self.disc(playAll), mainFeatureIndex: 12) == expected)
        #expect(DiscTitleHeuristic.classify(Self.disc(playAll.reversed()), mainFeatureIndex: 12) == expected)
        // A fixed interleaving, so the order differs from both sorted and reversed.
        let interleaved = stride(from: 0, to: playAll.count, by: 2).map { playAll[$0] }
            + stride(from: 1, to: playAll.count, by: 2).map { playAll[$0] }
        #expect(DiscTitleHeuristic.classify(Self.disc(interleaved), mainFeatureIndex: 12) == expected)

        let trap = Self.sumAllTrapDisc().titles
        #expect(DiscTitleHeuristic.classify(Self.disc(trap.reversed()), mainFeatureIndex: 1) == .single(index: 1, source: .scanner))
    }

    // MARK: - Against the real scan capture

    /// The only real HandBrake capture in this ticket's corpus: HandBrake's
    /// own `MainFeature` on the real Dragon Tattoo capture, run through
    /// `classify` unmodified. The other four titles are all under the
    /// 300 s pool minimum, so the Play All guard has nothing to cluster —
    /// this is the ordinary movie-disc path, end to end.
    @Test func classifiesTheRealDragonTattooCaptureAsASingleFeature() throws {
        let output = try Self.dragonTattooFixtureOutput()
        let outcome = DiscTitleHeuristic.classify(output.disc, mainFeatureIndex: output.mainFeatureIndex)
        #expect(outcome == .single(index: 1, source: .scanner))

        let roles = DiscTitleHeuristic.applyingSuggestedRoles(to: output.disc, mainFeatureIndex: output.mainFeatureIndex)
        #expect(roles.titles.first { $0.index == 1 }?.suggestedRole == .mainFeature)
        #expect(roles.titles.filter { $0.suggestedRole == .mainFeature }.count == 1)
    }

    /// #0056's real fixture, and the bug this ticket exists to fix:
    /// HandBrake reports `MainFeature: -1` on this disc — no answer at all —
    /// yet title 11 runs 2:26:53 across 16 chapters and nothing else on the
    /// disc exceeds ten minutes (titles 1–3 run 8–10 minutes). The
    /// 45-minute fallback must promote title 11 and record that the choice
    /// came from length, not the scan; `applyingSuggestedRoles` must agree.
    @Test func classifiesTheRealHornetsNestCaptureAsASingleFeatureByLength() throws {
        let text = try String(
            contentsOfFile: Self.fixturePath("discs/hornets-nest/scan.json"), encoding: .utf8
        )
        let output = HandBrakeScanParser.parse(text, volumeName: "HORNETS_NEST", driveName: "joe")

        #expect(!output.titleSetCorrupted)
        #expect(output.disc.titles.count == 11)
        #expect(output.mainFeatureIndex == -1)

        let outcome = DiscTitleHeuristic.classify(output.disc, mainFeatureIndex: output.mainFeatureIndex)
        #expect(outcome == .single(index: 11, source: .length))

        let roles = DiscTitleHeuristic.applyingSuggestedRoles(to: output.disc, mainFeatureIndex: output.mainFeatureIndex)
        #expect(roles.titles.first { $0.index == 11 }?.suggestedRole == .mainFeature)
        #expect(roles.titles.filter { $0.suggestedRole == .mainFeature }.count == 1)
    }

    /// #0055's headline pin, and the user's immediate ask: the real TV-season
    /// disc scanned on joe (#0025's "Real-disc confirmation" section),
    /// asserted by name for the first time. HandBrake's own `MainFeature`
    /// names the Play All title itself (14) among 32 titles — proving the
    /// Play All guard is not merely a hypothetical backstop, HandBrake will
    /// hand the app exactly the title it must refuse. Title 14 runs 2:53:33
    /// (10,413 s) with 33 chapters; the eight-title episode cluster
    /// (15–22, each 20:57–22:48) sums to 10,415 s — 0.02% error, comfortably
    /// inside the 2% tolerance with 31 other titles (short decoys and menu
    /// loops) available to be wrongly swept in and were not.
    @Test func classifiesTheRealTVSeasonCaptureAsPlayAll() throws {
        let text = try String(
            contentsOfFile: Self.fixturePath("discs/tv-season-playall/scan.json"), encoding: .utf8
        )
        let output = HandBrakeScanParser.parse(text, volumeName: "TV_SEASON", driveName: "joe")

        #expect(!output.titleSetCorrupted)
        #expect(output.disc.titles.count == 32)
        #expect(output.mainFeatureIndex == 14)

        let feature = try #require(output.disc.titles.first { $0.index == 14 })
        #expect(feature.durationSeconds == 2 * 3600 + 53 * 60 + 33) // 10,413 s
        #expect(feature.chapterCount == 33)

        let outcome = DiscTitleHeuristic.classify(output.disc, mainFeatureIndex: output.mainFeatureIndex)
        guard case .playAll(let index, let episodes) = outcome else {
            Issue.record("expected .playAll, got \(outcome)")
            return
        }
        #expect(index == 14)
        #expect(episodes == Array(15...22))

        let cluster = output.disc.titles.filter { episodes.contains($0.index) }
        let clusterTotal = cluster.reduce(0) { $0 + $1.durationSeconds }
        #expect(clusterTotal == 10_415) // 0.02% error against title 14's 10,413 s
        #expect(abs(clusterTotal - feature.durationSeconds) * 100 <= feature.durationSeconds * 2) // inside the 2% guard tolerance

        // The guard's own refusal, end to end: applyingSuggestedRoles must
        // never mark title 14 — or anything else — .mainFeature.
        let roles = DiscTitleHeuristic.applyingSuggestedRoles(to: output.disc, mainFeatureIndex: output.mainFeatureIndex)
        #expect(roles.titles.allSatisfy { $0.suggestedRole != .mainFeature })
    }

    // MARK: - The Play All guard against the real makemkvcon corpus

    /// The issue's fixture table, asserted against the committed captures
    /// rather than restated. The candidate on each disc is its longest title
    /// (the feature on every movie disc, the Play All title on the TV
    /// discs). Brooklyn Nine-Nine is the documented TV disc; The IT Crowd
    /// season 1 was captured but is not in the issue's table — its title 0
    /// (8,652 s) is also exactly the sum of six episodes, so the guard
    /// refuses it too.
    @Test(arguments: [
        ("brooklyn-nine-nine-min0.txt", 12, Array(13...20), 10_398),
        ("brooklyn-nine-nine-mindefault.txt", 3, Array(4...11), 10_398),
        ("the-it-crowd-season-1-min0.txt", 0, Array(1...6), 8_652),
        ("the-it-crowd-season-1-mindefault.txt", 0, Array(1...6), 8_652),
    ])
    func realTVDiscsArePlayAll(fixture: String, longest: Int, episodes: [Int], total: Int) throws {
        let titles = try Self.makemkvTitles(fixture)
        let candidate = try #require(titles.max { $0.durationSeconds < $1.durationSeconds })
        #expect(candidate.index == longest)
        #expect(candidate.durationSeconds == total)

        let cluster = try #require(DiscTitleHeuristic.playAllEpisodes(for: candidate, among: titles))
        #expect(cluster.map(\.index) == episodes)
        #expect(cluster.reduce(0) { $0 + $1.durationSeconds } == total) // 0.0% error, to the second
    }

    @Test(arguments: [
        "dragon-tattoo-min0.txt",
        "hanna-min0.txt", "hanna-mindefault.txt",
        "hornets-nest-min0.txt", "hornets-nest-mindefault.txt",
        "super-troopers-2-min0.txt", "super-troopers-2-mindefault.txt",
        "supertroopers-min0.txt", "supertroopers-mindefault.txt",
        "the-girl-in-the-spider-s-web-min0.txt", "the-girl-in-the-spider-s-web-mindefault.txt",
        "weird-science-min0.txt",
    ])
    func realMovieDiscsAreNotPlayAll(fixture: String) throws {
        let titles = try Self.makemkvTitles(fixture)
        #expect(titles.count >= 4)
        let candidate = try #require(titles.max { $0.durationSeconds < $1.durationSeconds })
        #expect(candidate.durationSeconds >= 45 * 60)
        #expect(DiscTitleHeuristic.playAllEpisodes(for: candidate, among: titles) == nil)
    }

    /// The documented negative result, on the real disc: summing *every*
    /// non-feature title on Super Troopers 2 (decoys included) gives 5,390 s
    /// against the 5,955 s feature — 0.905. The guard stays a movie.
    @Test func realSuperTroopers2SumAllRatioIsTheDocumentedNegativeResult() throws {
        let titles = try Self.makemkvTitles("super-troopers-2-min0.txt")
        let feature = try #require(titles.first { $0.index == 0 })
        #expect(feature.durationSeconds == 5_955)
        let sumAll = titles.filter { $0.index != 0 }.reduce(0) { $0 + $1.durationSeconds }
        #expect(sumAll == 5_390)
        #expect(sumAll * 1000 / feature.durationSeconds == 905)
        #expect(DiscTitleHeuristic.playAllEpisodes(for: feature, among: titles) == nil)
    }

    // MARK: - The Play All guard, synthetic

    @Test func brooklynNineNineIsAPlayAllDisc() {
        let outcome = DiscTitleHeuristic.classify(Self.brooklynNineNineDisc(), mainFeatureIndex: 12)

        guard case .playAll(let index, let episodes) = outcome else {
            Issue.record("expected .playAll, got \(outcome)")
            return
        }
        #expect(index == 12)
        #expect(episodes.count == 8)
        #expect(episodes == Array(13...20))
    }

    @Test func playAllEpisodeClusterMatchesTheDocumentedNumbers() throws {
        let candidate = Self.title(12, 10_398, chapters: 33)
        let episodes = DiscTitleHeuristic.playAllEpisodes(
            for: candidate,
            among: Self.brooklynNineNineDisc().titles
        )
        let cluster = try #require(episodes)
        #expect(cluster.count == 8)
        #expect(cluster.reduce(0) { $0 + $1.durationSeconds } == 10_398) // 0.0% error
    }

    /// Clustering is load-bearing: on this synthetic trap, summing the whole
    /// pool lands inside the 2% tolerance, so a "sum everything" regression
    /// would refuse a movie. The falsification in issues/0025.md's
    /// Verification ran exactly that mutation against this fixture.
    @Test func sumAllTrapIsAMovieOnlyBecauseOfClustering() {
        let disc = Self.sumAllTrapDisc()
        let feature = Self.title(1, 5_955, chapters: 25)

        // Pin the trap itself, so the fixture cannot drift into not being one.
        let sumAll = disc.titles.filter { $0.index != 1 }.reduce(0) { $0 + $1.durationSeconds }
        #expect(sumAll == 5_940)
        #expect(abs(sumAll - feature.durationSeconds) * 100
                <= feature.durationSeconds * DiscTitleHeuristic.playAllDurationTolerancePercent)

        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: 1) == .single(index: 1, source: .scanner))
        // The guard does find a ≥ 3 cluster here (five titles, 3,154 s); it
        // is the cluster's total missing the 2% match that returns nil.
        #expect(DiscTitleHeuristic.playAllEpisodes(for: feature, among: disc.titles) == nil)
    }

    /// A cluster of exactly 2 must not trip the guard — the ≥3 requirement.
    @Test func clusterOfExactlyTwoDoesNotTripTheGuard() {
        let disc = Self.disc([
            Self.title(1, 5_955, chapters: 25),
            Self.title(2, 1_200),
            Self.title(3, 1_250),   // within 15% of title 2 — but only two of them
            Self.title(4, 300),
        ])
        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: 1) == .single(index: 1, source: .scanner))
        #expect(DiscTitleHeuristic.playAllEpisodes(for: Self.title(1, 5_955, chapters: 25),
                                                   among: disc.titles) == nil)
    }

    /// Decoys under five minutes never count toward a cluster.
    @Test func decoysUnderFiveMinutesNeverJoinThePool() {
        // Nine 20-second decoys would otherwise be a tight "cluster".
        var titles = [Self.title(1, 5_955, chapters: 25)]
        for index in 2...10 { titles.append(Self.title(index, 20)) }
        #expect(DiscTitleHeuristic.playAllEpisodes(for: titles[0], among: titles) == nil)
    }

    // MARK: - applyingSuggestedRoles

    @Test func suggestedRolesFollowTheMainFeatureAndTheIgnoreCutoff() {
        let disc = Self.disc([
            Self.title(1, 9_478, chapters: 16),  // the feature
            Self.title(2, 600),                  // extra
            Self.title(3, 300),                  // exactly at the cutoff → extra
            Self.title(4, 299),                  // below the cutoff → ignore
            Self.title(5, 5),                    // decoy → ignore
        ])
        let roles = DiscTitleHeuristic.applyingSuggestedRoles(to: disc, mainFeatureIndex: 1)
        #expect(roles.titles.first { $0.index == 1 }?.suggestedRole == .mainFeature)
        #expect(roles.titles.first { $0.index == 2 }?.suggestedRole == .extra)
        #expect(roles.titles.first { $0.index == 3 }?.suggestedRole == .extra)
        #expect(roles.titles.first { $0.index == 4 }?.suggestedRole == .ignore)
        #expect(roles.titles.first { $0.index == 5 }?.suggestedRole == .ignore)
    }

    /// MainFeature 0 is a scan problem, never a scanner answer on its own —
    /// but #0056 folds it into "the scanner gave no answer" like an absent
    /// or unknown index, so it still falls back to the length threshold
    /// rather than refusing to promote anything at all. With nothing on the
    /// disc long enough to clear that bar either, nothing is marked the
    /// feature.
    @Test func mainFeatureZeroWithNoTitleClearingTheThresholdNeverMarksAFeature() {
        let disc = Self.disc([Self.title(1, 600), Self.title(2, 600)])
        let roles = DiscTitleHeuristic.applyingSuggestedRoles(to: disc, mainFeatureIndex: 0)
        #expect(!roles.titles.contains { $0.suggestedRole == .mainFeature })
        #expect(roles.titles.first { $0.index == 1 }?.suggestedRole == .extra)
    }

    /// The flip side, and the behavior change #0056 makes deliberately:
    /// MainFeature 0 no longer holds back promotion when exactly one title
    /// clears 45 minutes — it falls back exactly like an absent or unknown
    /// index would, because a scan artefact and "the scanner didn't answer"
    /// are the same case now.
    @Test func mainFeatureZeroStillFallsBackToLengthWhenExactlyOneTitleClearsTheThreshold() {
        let disc = Self.disc([Self.title(1, 9_478), Self.title(2, 600)])
        let roles = DiscTitleHeuristic.applyingSuggestedRoles(to: disc, mainFeatureIndex: 0)
        #expect(roles.titles.first { $0.index == 1 }?.suggestedRole == .mainFeature)
        #expect(roles.titles.filter { $0.suggestedRole == .mainFeature }.count == 1)
    }

    /// The regression this ticket exists to prevent: `applyingSuggestedRoles`
    /// must be built on `classify`, not a parallel reimplementation that
    /// only looks at `mainFeatureIndex`. If it ever drifts back to that, a
    /// Play All disc would have its title silently marked `.mainFeature`
    /// even though `classify` correctly refuses it — the "rip a TV season
    /// into the Movies library, confidently and silently" failure.
    @Test func suggestedRolesNeverMarkAFeatureOnAPlayAllDisc() {
        let roles = DiscTitleHeuristic.applyingSuggestedRoles(to: Self.brooklynNineNineDisc(), mainFeatureIndex: 12)
        #expect(!roles.titles.contains { $0.suggestedRole == .mainFeature })
    }
}

// MARK: - #0065: the scanner's answer is not taken on trust

@Suite struct ScannerAnswerSanityTests {

    private static func title(_ index: Int, _ seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 1,
                  sizeBytes: 0, outputFileName: nil)
    }

    private static func disc(_ titles: [DiscTitle]) -> DiscInfo {
        DiscInfo(volumeName: "IDENTITY", driveName: "disk4", titles: titles)
    }

    /// The Bourne Identity, measured 2026-09-24: HandBrake reported
    /// `+ title 13: + Main Feature` on a 00:02:26 trailer, while the feature
    /// was one of three ~90-minute titles. Encoding it would have spent forty
    /// minutes producing a trailer and filed it in Plex as the film.
    @Test func aTrailerTheScannerCallsTheMainFeatureIsRefused() {
        let disc = Self.disc([
            Self.title(1, 5397),   // 1:29:57 widescreen
            Self.title(2, 5464),   // 1:31:04 widescreen
            Self.title(3, 5397),   // 1:29:57 4:3 pan-and-scan
            Self.title(13, 146),   // 0:02:26 — what HandBrake named
        ])
        let outcome = DiscTitleHeuristic.classify(disc, mainFeatureIndex: 13)
        // Three titles clear the floor, so no single one can be promoted:
        // the right answer for a genuinely ambiguous disc is to ask.
        #expect(outcome == .none, "a 2:26 title is not a feature, whoever says so")
    }

    /// The floor is the only thing added — a scanner answer that is plausible
    /// is still believed, and still preferred over guessing by length.
    @Test func aPlausibleScannerAnswerIsStillTrusted() {
        let disc = Self.disc([Self.title(1, 5400), Self.title(2, 5460), Self.title(9, 200)])
        let outcome = DiscTitleHeuristic.classify(disc, mainFeatureIndex: 2)
        #expect(outcome == .single(index: 2, source: .scanner))
    }

    /// Exactly at the floor is long enough. The boundary is stated so a later
    /// refactor cannot quietly turn `>=` into `>`.
    @Test func exactlyTheMinimumCounts() {
        let disc = Self.disc([
            Self.title(1, DiscTitleHeuristic.featureMinimumSeconds),
            Self.title(2, 120),
        ])
        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: 1) == .single(index: 1, source: .scanner))
    }

    /// One second under, and it falls through to the length fallback — which
    /// here finds no candidate at all and asks a person.
    @Test func oneSecondUnderTheFloorIsRefused() {
        let disc = Self.disc([
            Self.title(1, DiscTitleHeuristic.featureMinimumSeconds - 1),
            Self.title(2, 120),
        ])
        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: 1) == .none)
    }

    /// A short scanner answer must not block a disc that has one obvious
    /// feature: the fallback still runs and still promotes it.
    @Test func aShortScannerAnswerStillLetsTheLengthFallbackWork() {
        let disc = Self.disc([Self.title(1, 5400), Self.title(13, 146)])
        let outcome = DiscTitleHeuristic.classify(disc, mainFeatureIndex: 13)
        #expect(outcome == .single(index: 1, source: .length))
    }
}

// MARK: - #0066: flipper discs (widescreen beside 4:3)

@Suite struct WidescreenPreferenceTests {

    private static func title(_ index: Int, _ seconds: Int, aspect: Double?) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 28,
                  sizeBytes: 0, outputFileName: nil, displayAspect: aspect)
    }

    private static func disc(_ titles: [DiscTitle]) -> DiscInfo {
        DiscInfo(volumeName: "IDENTITY", driveName: "disk4", titles: titles)
    }

    /// Identity, measured on joe 2026-09-24. Titles 1 and 3 are both
    /// 1:29:57 with 28 chapters and identical audio; 1 is display aspect
    /// 1.78 and 3 is 1.33, and the disc labels their subtitles "(Wide
    /// Screen)" and "(4:3)". Before this, two titles cleared the floor so
    /// the app had to ask.
    @Test func aPanAndScanTwinIsDroppedInFavourOfWidescreen() {
        let kept = DiscTitleHeuristic.widescreenPreferred([
            Self.title(1, 5397, aspect: 1.78),
            Self.title(3, 5397, aspect: 1.33),
        ])
        #expect(kept.map(\.index) == [1])
    }

    /// The whole point: what was ambiguous becomes answerable without a
    /// person. Title 2 is 67 seconds longer — extra front-matter — so it is
    /// not a twin and the disc still has two real candidates.
    @Test func theRealDiscStillNeedsAPersonForTheOtherPair() {
        let disc = Self.disc([
            Self.title(1, 5397, aspect: 1.78),
            Self.title(2, 5464, aspect: 1.78),
            Self.title(3, 5397, aspect: 1.33),
        ])
        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: nil) == .none)
    }

    /// With the pan-and-scan twin gone and no second widescreen title, the
    /// disc resolves on its own.
    @Test func aPlainFlipperDiscNoLongerNeedsAsking() {
        let disc = Self.disc([
            Self.title(1, 5397, aspect: 1.78),
            Self.title(3, 5397, aspect: 1.33),
            Self.title(9, 146, aspect: 1.78),
        ])
        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: nil) == .single(index: 1, source: .length))
    }

    /// A 4:3 disc with no widescreen version keeps everything. Anything
    /// pre-1953, and most television, is 4:3 throughout — dropping those
    /// would lose the feature entirely.
    @Test func aDiscThatIsFourThreeThroughoutKeepsEveryTitle() {
        let titles = [Self.title(1, 5397, aspect: 1.33), Self.title(2, 900, aspect: 1.33)]
        #expect(DiscTitleHeuristic.widescreenPreferred(titles).map(\.index) == [1, 2])
    }

    /// Same shape, end to end: the 4:3 feature is still promoted.
    @Test func aFourThreeFeatureIsStillFound() {
        let disc = Self.disc([Self.title(1, 5397, aspect: 1.33), Self.title(2, 146, aspect: 1.33)])
        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: nil) == .single(index: 1, source: .length))
    }

    /// A 4:3 title of a *different* length is its own programme, not a twin
    /// — a 4:3 documentary beside a widescreen feature must survive.
    @Test func aFourThreeTitleOfADifferentLengthIsNotATwin() {
        let titles = [Self.title(1, 5397, aspect: 1.78), Self.title(4, 3600, aspect: 1.33)]
        #expect(DiscTitleHeuristic.widescreenPreferred(titles).map(\.index) == [1, 4])
    }

    /// A scan that reported no geometry changes nothing — the rule can only
    /// ever remove a title it has positive evidence about.
    @Test func titlesWithNoAspectReportedAreUntouched() {
        let titles = [Self.title(1, 5397, aspect: nil), Self.title(3, 5397, aspect: nil)]
        #expect(DiscTitleHeuristic.widescreenPreferred(titles).map(\.index) == [1, 3])
    }
}
