import Testing
@testable import Changeover

/// #0068 — "on this disc there are 3 titles which are about 90 minutes… When
/// we have 3 options like this one we can offer a recommendation instead of
/// an automatic selection."
@Suite struct TitleRecommendationTests {

    private static func title(_ index: Int, _ seconds: Int, aspect: Double? = 1.78) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 28,
                  sizeBytes: 0, outputFileName: nil, displayAspect: aspect)
    }

    /// Identity, measured on joe. Titles 1 and 3 are 1:29:57 (widescreen and
    /// pan-and-scan), title 2 is 1:31:04, and TMDB lists 90 minutes. Title 1
    /// is 3 seconds off the listing; title 2 is 64 seconds off — so both are
    /// "near", and that is precisely when the app must recommend rather than
    /// decide.
    @Test func theRealDiscLeansToTitleOneWithoutClaimingCertainty() throws {
        let suggestion = try #require(TitleRecommendation.suggest(
            titles: [Self.title(1, 5397), Self.title(2, 5464), Self.title(3, 5397, aspect: 1.33)],
            runtimeSeconds: 5400
        ))
        #expect(suggestion.index == 1)
        #expect(suggestion.strength == .leaning)
    }

    /// The 2:26 title that started all this can never be suggested, whatever
    /// else is on the disc.
    @Test func anImplausiblyShortTitleIsNeverSuggested() throws {
        let suggestion = try #require(TitleRecommendation.suggest(
            titles: [Self.title(1, 5397), Self.title(13, 146)],
            runtimeSeconds: 5400
        ))
        #expect(suggestion.index == 1)
        #expect(suggestion.strength == .certain, "one candidate, matching the listing, is not a guess")
    }

    /// When only one title is anywhere near the listing, the app may select
    /// without asking — that is the whole point of separating the two.
    @Test func oneClearMatchIsCertain() throws {
        let suggestion = try #require(TitleRecommendation.suggest(
            titles: [Self.title(1, 5400), Self.title(2, 3000), Self.title(3, 2400)],
            runtimeSeconds: 5400
        ))
        #expect(suggestion.index == 1)
        #expect(suggestion.strength == .certain)
    }

    /// No movie chosen yet, so no listing: the longest is the usual answer
    /// and never a confident one, because a Play All title looks like this.
    @Test func withNoListingItLeansToTheLongest() throws {
        let suggestion = try #require(TitleRecommendation.suggest(
            titles: [Self.title(1, 5397), Self.title(2, 5464)],
            runtimeSeconds: nil
        ))
        #expect(suggestion.index == 2)
        #expect(suggestion.strength == .leaning)
    }

    /// A disc of nothing but trailers has no feature to suggest, and saying
    /// so is better than nominating the least-short one.
    @Test func aDiscWithNoPlausibleFeatureSuggestsNothing() {
        #expect(TitleRecommendation.suggest(
            titles: [Self.title(6, 69), Self.title(7, 58), Self.title(13, 146)],
            runtimeSeconds: 5400
        ) == nil)
    }

    /// The pan-and-scan twin is never the recommendation, even when it is
    /// exactly as close to the listing as its widescreen counterpart.
    @Test func theRecommendationIsNeverThePanAndScanTransfer() throws {
        let suggestion = try #require(TitleRecommendation.suggest(
            titles: [Self.title(3, 5397, aspect: 1.33), Self.title(1, 5397, aspect: 1.78)],
            runtimeSeconds: 5400
        ))
        #expect(suggestion.index == 1)
    }

    /// Every suggestion carries a reason a person can read; a recommendation
    /// nobody can evaluate is just an unexplained default.
    @Test func everySuggestionSaysWhy() throws {
        let suggestion = try #require(TitleRecommendation.suggest(
            titles: [Self.title(1, 5397), Self.title(2, 5464)], runtimeSeconds: 5400))
        #expect(!suggestion.reason.isEmpty)
        #expect(suggestion.reason.first?.isUppercase == true)
    }

    /// The reason is written as a standalone clause but shown mid-sentence,
    /// so it has to survive being lowercased without losing a proper noun.
    @Test func aReasonReadsAsPartOfASentence() {
        #expect("Its length matches what this movie should be".lowercasedFirst
                == "its length matches what this movie should be")
        #expect("".lowercasedFirst == "")
    }
}
