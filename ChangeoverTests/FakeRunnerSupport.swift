import Foundation
@testable import Changeover

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
