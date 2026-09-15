import Foundation
@testable import Changeover

/// #0041 review — a fake `JobController.Runner`'s success, reached the way
/// the real `DVDPipeline` reaches it: `.encoding`, then `.organizing`, then
/// the outcome. `JobController.finish` logs an outcome that can't follow the
/// last reported phase (`.starting → .succeeded` is illegal), so a fake that
/// returned `.succeeded` without reporting would break the `Runner` contract
/// and add a warning line to the job's log.
@MainActor
func fakeSuccess(_ reportPhase: @MainActor (JobPhase) -> Void, destination: URL) -> JobOutcome {
    reportPhase(.encoding)
    reportPhase(.organizing)
    return .succeeded(destination: destination)
}
