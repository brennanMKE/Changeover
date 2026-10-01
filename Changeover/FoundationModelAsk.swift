import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// #0175 — one place that talks to the on-device model.
///
/// `DiscTitleInference` and `MultiTitleInference` each carry their own copy of
/// the availability check, the session construction and the `#if
/// canImport(FoundationModels)` dance. `DiscInterrogation` asks several
/// questions rather than one, so a third copy would have been the point where
/// they start to drift — one of them pinned to greedy sampling, another not,
/// and nobody able to say which build answered which way.
///
/// Greedy sampling, deliberately: the same evidence must give the same answer
/// twice, or a disc that identifies itself on one insertion and not the next
/// is indistinguishable from a bug.
nonisolated enum FoundationModelAsk {

    /// `nil` when there is no model, when it declines, or when it throws —
    /// three different situations that are one situation to every caller:
    /// no answer, carry on without it.
    @concurrent
    static func respond(instructions: String, prompt: String) async -> String? {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: prompt, options: GenerationOptions(sampling: .greedy))
                return response.content
            } catch {
                return nil
            }
        }
        return nil
#else
        return nil
#endif
    }
}
