import Foundation

/// #0227 — where one extra of a job got to.
///
/// The extras loop in `DVDPipeline` is deliberately forgiving: a failed extra
/// is logged and skipped rather than failing the job, because the feature is
/// already in Plex by then and losing it to a bad featurette would be the worse
/// trade (#0031). The cost is that the failure then exists **only in the log**.
/// A job can finish `succeeded` having produced three of four extras, and
/// nothing in the window or in `status` says which one was lost — the user sees
/// "Added to Plex" and a folder quietly missing a file.
///
/// `DiscRipPlan.Entry.State` already solved this shape for *films*: waiting,
/// running, done, failed, skipped, each rendered as a row with its own status.
/// This is the same idea one level down, for the extras inside a single job.
///
/// Deliberately a flat record per title index rather than a mutable plan.
/// `ExtrasPlan` is resolved once at start and must not change while the job
/// runs — it is what the job promised to produce — so progress is tracked
/// beside it rather than inside it.
nonisolated enum ExtraOutcome: Equatable, Sendable, Codable {
    /// Not reached yet.
    case waiting
    /// Encoding now.
    case running
    /// Encoded and filed.
    case done
    /// Encoding failed, or the file it produced was refused. The job carries
    /// on; this is why the row has to say so.
    case failed(reason: String)
    /// Never attempted — the job was cancelled, or the feature came from the
    /// MakeMKV fallback and extras were skipped wholesale (#0035).
    case skipped(reason: String)

    /// Whether this extra will produce nothing, so a caller counting what the
    /// disc actually yielded does not have to match on three cases.
    var isUnproduced: Bool {
        switch self {
        case .failed, .skipped: return true
        case .waiting, .running, .done: return false
        }
    }

    /// The wire name, for `status`. A plain string for the reason every
    /// identifier that crosses the bridge is one: an unknown value from a newer
    /// app must degrade to "I do not recognise this" rather than fail the
    /// decode of the whole reply.
    var name: String {
        switch self {
        case .waiting: return "waiting"
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        case .skipped: return "skipped"
        }
    }

    /// Why, when there is a why. `nil` for the three states that need none.
    var reason: String? {
        switch self {
        case .failed(let reason), .skipped(let reason): return reason
        case .waiting, .running, .done: return nil
        }
    }
}
