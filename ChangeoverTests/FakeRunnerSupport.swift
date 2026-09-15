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
