import Foundation

/// One sentence in two registers (`docs/plain-language-ui.md` §1.4).
///
/// `plain` is what a person with no vocabulary for DVDs reads by default:
/// one short sentence, no tool names, no identifiers, rounded numbers.
/// `detail` is the **existing precise wording, verbatim** — the string that
/// was written to answer a specific past failure — or `nil` when `plain`
/// already meets both bars.
///
/// File-scope and `nonisolated`, like `StartDecision` and
/// `ScanStatusLine.Line`: what a step says is a value, not something a view
/// decides.
nonisolated struct Wording: Equatable, Sendable {
    var plain: String
    /// The verbatim precise sentence, or `nil` when `plain` is already it.
    var detail: String?

    init(plain: String, detail: String? = nil) {
        self.plain = plain
        self.detail = detail
    }

    /// A sentence that needs no second register.
    static func plainOnly(_ text: String) -> Wording {
        Wording(plain: text)
    }

    /// What to draw: `[plain]`, or `[plain, detail]` with Details open.
    ///
    /// Never the same sentence twice — a `detail` equal to `plain` is the
    /// "this string already met the plain register" case, and repeating it
    /// under itself would read as a bug.
    func lines(showingDetails: Bool) -> [String] {
        guard showingDetails, let detail, detail != plain else { return [plain] }
        return [plain, detail]
    }
}
