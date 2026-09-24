import SwiftUI

/// A secondary action drawn as an SF Symbol instead of a line of text.
///
/// `docs/plain-language-ui.md` §4 keeps the default screen quiet, and the two
/// actions that use this — showing the log and revealing a file in Finder —
/// are the ones a non-technical user never needs. As text they read as
/// instructions and compete with the button that is actually the way forward;
/// as a symbol they sit out of the way until somebody goes looking.
///
/// The words do not disappear, they move: `title` is both the tooltip and the
/// accessibility label, so hovering says what it does and VoiceOver reads the
/// same sentence it read before.
struct IconActionButton: View {
    /// An SF Symbol name.
    let symbol: String
    /// What it does, as a short phrase — shown on hover, read aloud by
    /// VoiceOver. Never decoration: an icon-only control with no label is
    /// unusable without sight and a guess with it.
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .imageScale(.medium)
                // A fixed box so a row of these lines up regardless of how
                // wide each glyph happens to be.
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

extension IconActionButton {
    /// The two symbols this app uses, named once so three call sites cannot
    /// drift apart.
    enum Symbol {
        /// Lines of text in a frame — the job's log.
        static let log = "list.bullet.rectangle"
        /// Finder's own metaphor for "here is where the file is".
        static let reveal = "folder"
    }
}
