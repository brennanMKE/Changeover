import Foundation
@testable import Changeover

/// #0050 — shared eject-related test support, so no pipeline/controller test
/// has to fall back to `DVDPipeline`'s or `JobController`'s default ejector,
/// which resolves to the real `DiscEjector`/`DiskArbitration`. Found in the
/// #0049 review: `DVDPipeline.eject` and `JobController`'s `Ejector` default
/// both point at `DiscEjector.eject`, and most existing pipeline tests never
/// overrode it, so a successful test run issued a real unmount/eject against
/// a temp-directory path. `DiscEjector.defaultEject` now refuses on its own
/// under a test host (see `DiscEjectorTests`), so this is belt-and-braces —
/// it also keeps tests from depending on that guard's exact refusal message.
enum PipelineTestSupport {
    /// A no-op fake ejector for the (large majority of) tests that don't
    /// exercise or assert anything about the eject step itself. Always
    /// reports `.ejected` and never touches `DiscEjector`. Assign it with
    /// `pipeline.eject = PipelineTestSupport.fakeEject` right after
    /// constructing a `DVDPipeline`, or pass `ejector: PipelineTestSupport.fakeEject`
    /// to `JobController.init`.
    static let fakeEject: @MainActor (URL) async -> DiscEjector.Outcome = { _ in .ejected }
}

/// #0050 — a recording fake ejector for the tests that *do* care which
/// volume URL was ejected, or want to script a specific `DiscEjector.Outcome`
/// (busy, failed, unmounted-but-not-ejected, …). Shared so
/// `JobControllerEjectTests` and any pipeline test with the same need don't
/// each keep their own private copy.
@MainActor
final class RecordingEjector {
    private(set) var calls: [URL] = []
    var outcome: DiscEjector.Outcome = .ejected

    func eject(_ url: URL) async -> DiscEjector.Outcome {
        calls.append(url)
        return outcome
    }
}

/// #0041 review — a fake `JobController.Runner`'s success, reached the way
/// the real `DVDPipeline` reaches it: `.encoding`, then `.organizing`, then
/// the outcome. `JobController.finish` logs an outcome that can't follow the
/// last reported phase (`.starting → .succeeded` is illegal), so a fake that
/// returned `.succeeded` without reporting would break the `Runner` contract
/// and add a warning line to the job's log.
///
/// #0042: takes the whole `JobContext` rather than just its `phase` closure.
/// Extracting `context.phase` as a bare function value at a test call site
/// (`fakeSuccess(context.phase, destination:)`) produced a "converting
/// non-Sendable function value" warning at every call site — the same
/// bound-method pattern #0045's Gotcha already ran into with `ejector.eject`
/// — because passing a closure-typed *property* on a non-`Sendable` struct
/// as an argument is diagnosed differently from calling it directly. Calling
/// `context.phase(...)` from inside here, instead of handing the closure
/// value itself to a caller, sidesteps that entirely.
@MainActor
func fakeSuccess(_ context: JobController.JobContext, destination: URL) -> JobOutcome {
    context.phase(.encoding)
    context.phase(.organizing)
    return .succeeded(destination: destination)
}

/// #0046 — a fake `JobController.Runner` that reports `phase`, then blocks
/// until its own `Task` is actually cancelled (polling `Task.isCancelled`,
/// since there is no real subprocess suspension point to hang a
/// cancellation handler off), and returns the same shape a real cancelled
/// `DVDPipeline.run()` does: a `.failed` outcome whose reason is
/// `.cancelled`. `FallbackPolicy.isDiscShaped` already excludes `.cancelled`
/// (`FallbackPolicy.swift`), so nothing about the fallback needs to be
/// re-proven here — this exists to exercise `JobController.cancel(id:)`'s
/// own wiring (the phase check, `task?.cancel()`, `finish` moving the job
/// into `history` and releasing the sleep assertion), not `DVDPipeline`'s
/// internals, which get their own direct coverage.
///
/// Never returns on its own — a test that starts a job with this runner and
/// never calls `cancel(id:)` will hang forever, same as any other test that
/// parks a fake runner on a `Gate` it never opens.
@MainActor
func fakeCancel(_ context: JobController.JobContext, phase: JobPhase = .encoding, stage: JobStage = .encode) async -> JobOutcome {
    context.phase(phase)
    while !Task.isCancelled {
        await Task.yield()
    }
    return .failed(JobFailure(stage: stage, reason: .cancelled))
}
