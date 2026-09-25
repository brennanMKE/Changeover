import Foundation
import Testing
@testable import Changeover

/// #0071 — "the poster is too small to see detail… listing the lead actors
/// and director would make The American with George Clooney the obvious
/// choice."
@Suite struct CreditsLineTests {

    @Test func theLineReadsAsCastThenDirector() {
        #expect(CreditsLine.summary(
            cast: ["George Clooney", "Violante Placido"],
            director: "Anton Corbijn")
            == "George Clooney, Violante Placido · dir. Anton Corbijn")
    }

    /// TMDB knows plenty of films it has no credits for. Those rows keep the
    /// shape they have always had rather than gaining an empty line or the
    /// word "Unknown".
    @Test func aFilmWithNobodyCreditedGetsNoLine() {
        #expect(CreditsLine.summary(cast: [], director: nil) == nil)
        #expect(CreditsLine.summary(cast: [], director: "") == nil)
    }

    /// Either half alone is still worth showing.
    @Test func castAloneAndDirectorAloneBothStand() {
        #expect(CreditsLine.summary(cast: ["Bruce Willis"], director: nil) == "Bruce Willis")
        #expect(CreditsLine.summary(cast: [], director: "John McTiernan") == "dir. John McTiernan")
    }

    // MARK: - Decoding what TMDB actually sends

    private func details(_ json: String) throws -> TMDBMovieDetails {
        try JSONDecoder().decode(TMDBMovieDetails.self, from: Data(json.utf8))
    }

    /// `append_to_response=credits` nests them under the details, on the
    /// same request the runtime already costs.
    @Test func creditsDecodeFromAnAppendedResponse() throws {
        let d = try details("""
        {"id":27579,"title":"The American","runtime":105,
         "credits":{"cast":[{"name":"George Clooney","order":0},
                            {"name":"Violante Placido","order":1},
                            {"name":"Thekla Reuten","order":2},
                            {"name":"Paolo Bonacelli","order":3}],
                    "crew":[{"name":"Anton Corbijn","job":"Director"},
                            {"name":"Rowan Joffe","job":"Screenplay"}]}}
        """)
        #expect(d.leadCast == ["George Clooney", "Violante Placido", "Thekla Reuten"],
                "three names, in billing order — the fourth has never settled anything")
        #expect(d.director == "Anton Corbijn")
        #expect(d.runtimeMinutes == 105)
    }

    /// "Co-Director" and "Second Unit Director" are not the director, so the
    /// job is matched exactly.
    @Test func onlyAnExactDirectorCreditCounts() throws {
        let d = try details("""
        {"id":1,"credits":{"crew":[{"name":"A Person","job":"Second Unit Director"},
                                   {"name":"Real Director","job":"Director"}]}}
        """)
        #expect(d.director == "Real Director")
    }

    /// A response with no credits key at all must still decode — every older
    /// cached entry and every sparse film looks like this.
    @Test func detailsWithoutCreditsStillDecode() throws {
        let d = try details(#"{"id":1,"title":"X","runtime":90}"#)
        #expect(d.credits == nil)
        #expect(d.leadCast.isEmpty)
        #expect(d.director == nil)
        #expect(CreditsLine.summary(details: d) == nil)
    }

    /// The whole point, stated as a test: two films of the same name and
    /// nearly the same length, told apart by who is in them.
    @Test func castSeparatesTwoFilmsOfTheSameName() throws {
        let clooney = try details("""
        {"id":27579,"title":"The American","runtime":105,
         "credits":{"cast":[{"name":"George Clooney","order":0}],
                    "crew":[{"name":"Anton Corbijn","job":"Director"}]}}
        """)
        let other = try details("""
        {"id":999,"title":"The American","runtime":103,
         "credits":{"cast":[{"name":"Someone Else","order":0}],"crew":[]}}
        """)
        #expect(CreditsLine.summary(details: clooney)?.contains("George Clooney") == true)
        #expect(CreditsLine.summary(details: other)?.contains("George Clooney") != true)
    }
}
