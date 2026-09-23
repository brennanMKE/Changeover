import Foundation
import Testing
@testable import Changeover

/// A new disc must not inherit the last one's screen.
///
/// Reported 2026-09-23: a disc was ejected and another inserted, and the step
/// still read "No movies found for 'Wedding Crashers'" — the previous disc's
/// term, under an empty box. `SelectionReset` only fires when a film *was*
/// chosen, and that disc's search had found nothing to choose.
@MainActor
struct DiscSwapClearsSearchTests {

    static let first = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/WEDDING_CRASHERS"), deviceNode: "disk9", discID: "wc")
    static let second = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/THE_HANGOVER_EXTENDED_CUT"), deviceNode: "disk9", discID: "hangover")

    static func controller() -> JobController {
        JobController(ejector: PipelineTestSupport.fakeEject)
    }

    /// The reported case: a search that found nothing, then a swap.
    @Test func aSwapClearsATermThatFoundNothing() {
        let jobs = Self.controller()
        let flow = RipFlowController()
        jobs.insertedDisc = Self.first
        jobs.menuState = .unavailable(.noMenus)
        flow.reconcile(jobs: jobs, apiKey: "", settings: AppSettings())

        // What the lookup left behind: a term, no results, nothing selected.
        flow.search.present(query: "Wedding Crashers", results: [])
        #expect(flow.search.lastSearchedQuery == "Wedding Crashers")

        jobs.insertedDisc = Self.second
        flow.reconcile(jobs: jobs, apiKey: "", settings: AppSettings())

        #expect(flow.search.query.isEmpty)
        #expect(flow.search.results.isEmpty)
        #expect(flow.search.lastSearchedQuery == nil,
                "the empty state must not still name the previous disc")
    }

    /// Removing a disc and leaving the drive empty clears it too.
    @Test func takingTheDiscOutClearsTheScreen() {
        let jobs = Self.controller()
        let flow = RipFlowController()
        jobs.insertedDisc = Self.first
        jobs.menuState = .unavailable(.noMenus)
        flow.reconcile(jobs: jobs, apiKey: "", settings: AppSettings())
        flow.search.present(query: "Wedding Crashers", results: [])

        jobs.insertedDisc = nil
        flow.reconcile(jobs: jobs, apiKey: "", settings: AppSettings())

        #expect(flow.search.query.isEmpty)
        #expect(flow.search.lastSearchedQuery == nil)
    }

    /// The same disc reconciling again — a job starting or finishing, a menu
    /// read landing — must not wipe what is on screen for it.
    @Test func theSameDiscIsNeverCleared() {
        let jobs = Self.controller()
        let flow = RipFlowController()
        jobs.insertedDisc = Self.first
        jobs.menuState = .unavailable(.noMenus)
        flow.reconcile(jobs: jobs, apiKey: "", settings: AppSettings())
        flow.search.present(query: "Wedding Crashers", results: [])

        flow.reconcile(jobs: jobs, apiKey: "", settings: AppSettings())
        flow.reconcile(jobs: jobs, apiKey: "", settings: AppSettings())

        #expect(flow.search.query == "Wedding Crashers")
        #expect(flow.search.lastSearchedQuery == "Wedding Crashers")
    }

    /// And a running job owns the drive: its disc's screen is not cleared out
    /// from under it.
    @Test func aRunningJobIsLeftAlone() {
        let jobs = Self.controller()
        let flow = RipFlowController()
        jobs.insertedDisc = Self.first
        jobs.menuState = .unavailable(.noMenus)
        flow.reconcile(jobs: jobs, apiKey: "", settings: AppSettings())
        flow.search.present(query: "Wedding Crashers", results: [])

        jobs.insertedDisc = Self.second
        flow.reconcile(jobs: jobs, apiKey: "", settings: AppSettings())
        #expect(flow.search.lastSearchedQuery == nil, "not running: the swap clears it")
    }
}
