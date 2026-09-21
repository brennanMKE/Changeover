import Foundation

/// What `changeover-menudump --check` reports: which of the DVD libraries the
/// host has, where they were found, and the exact `brew install` line for the
/// ones it does not.
///
/// **Nothing is bundled.** Everything installable through Homebrew —
/// `libdvdread`, `libdvdcss`, `lsdvd`, `ffmpeg`, `HandBrakeCLI` — is located
/// on the host at runtime and never shipped inside the app. That makes "is it
/// installed, and what do I type to install it" a question the app has to be
/// able to answer, which is what this type and `DependencyPanel` are for.
/// (`docs/menu-intelligence.md` §2 predates the decision and is obsolete.)
///
/// Format `changeover-menu-dependencies/1`. The same shape the `helper` block
/// of `menus/structure.json` carries, so one decoder serves both "I asked
/// what is installed" and "I read a disc and this is what I had".
nonisolated struct MenuDependencies: Codable, Equatable, Sendable {

    nonisolated struct Helper: Codable, Equatable, Sendable {
        var name: String
        var version: String
    }

    nonisolated struct Library: Codable, Equatable, Sendable {
        /// `"available"` or `"missing"`.
        var status: String
        /// Where it was `dlopen`ed from, when it was.
        var path: String?
        /// The Homebrew formula name, e.g. `libdvdcss`.
        var formula: String?
        /// The exact command that fixes it, e.g. `brew install libdvdcss`.
        var install: String?

        var isAvailable: Bool { status == "available" }
    }

    var format: String
    var helper: Helper?
    var libdvdread: Library?
    var libdvdcss: Library?

    static func decode(_ data: Data) throws -> MenuDependencies {
        try JSONDecoder().decode(MenuDependencies.self, from: data)
    }

    /// The helper prints the report and nothing else, but a shell can add a
    /// line to anything, so the JSON object is taken from the first `{`.
    static func parse(_ text: String) -> MenuDependencies? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        let data = Data(text[start...].utf8)
        return try? decode(data)
    }

    var libraries: [Library] { [libdvdread, libdvdcss].compactMap { $0 } }

    /// Formula names the host is missing, in report order.
    var missingFormulae: [String] {
        libraries.filter { !$0.isAvailable }.compactMap(\.formula)
    }

    /// The commands that fix `missingFormulae`, deduplicated.
    var installCommands: [String] {
        var seen = Set<String>()
        return libraries
            .filter { !$0.isAvailable }
            .compactMap(\.install)
            .filter { seen.insert($0).inserted }
    }

    /// Tier 1 — buttons, targets, the title table, chapter counts — needs no
    /// library at all: IFO tables and NAV packs are never scrambled. Only the
    /// *picture* is, so this is what decides whether there can be stills, and
    /// therefore OCR, chapter names and language hints.
    var canReadMenuVideo: Bool {
        (libdvdread?.isAvailable ?? false) && (libdvdcss?.isAvailable ?? false)
    }
}

// MARK: - The Settings panel's rows

/// Every external tool and library the app can use, whether the host has it,
/// and what to type when it does not — the whole content of the Settings
/// dependency panel, as plain values.
///
/// Pure on purpose: the panel is a table with exactly one interesting rule
/// (required versus optional, installed versus missing, and the `brew` line
/// that goes with missing), and that rule is testable with no process, no
/// disc and no window.
nonisolated enum DependencyPanel {

    nonisolated enum Status: Equatable, Sendable {
        /// The probe has not finished yet.
        case checking
        case installed(detail: String?)
        case missing
        /// Present but not usable as configured — a path that points at the
        /// GUI app, a `--help` that is missing a flag Changeover needs.
        case unusable(detail: String)
    }

    nonisolated enum Role: String, Equatable, Sendable {
        /// Without it, no rip happens at all.
        case required
        /// Without it, one enrichment is missing and the rip is unchanged.
        case optional
    }

    nonisolated struct Row: Equatable, Sendable, Identifiable {
        var id: String { name }
        var name: String
        var role: Role
        var status: Status
        /// What it is for, one short clause.
        var purpose: String
        /// The exact command that installs it, shown only when it is missing.
        var install: String?

        var isMissing: Bool {
            if case .missing = status { return true }
            return false
        }
    }

    /// The install line for each tool this app can use. Kept here, beside the
    /// rows, so the panel and `SettingsView`'s Detect note cannot disagree.
    static let handbrakeInstall  = "brew install handbrake"
    static let makemkvconInstall = "brew install --cask makemkv"
    static let lsdvdInstall      = "brew install lsdvd"
    static let ffmpegInstall     = "brew install ffmpeg"
    static let libdvdreadInstall = "brew install libdvdread"
    static let libdvdcssInstall  = "brew install libdvdcss"

    /// The helper is this repository's own C program, not a Homebrew formula,
    /// so its "install line" is how to build it.
    static let menudumpInstall = "make -C Tools/menudump && cp Tools/menudump/build/changeover-menudump /usr/local/bin/"

    /// Maps a probed `ToolState` onto a row status. A path that is set but
    /// wrong is `.missing` for an optional tool (there is nothing to fix but
    /// the install), and `.unusable` when the state says what is wrong.
    static func status(_ state: ToolState?) -> Status {
        switch state {
        case nil:                    return .checking
        case .ready:                 return .installed(detail: nil)
        case .notSet:                return .missing
        case .notFound:              return .missing
        case .notExecutable:         return .missing
        case .insideAppBundle:       return .unusable(detail: "That is the HandBrake app, not HandBrakeCLI")
        case .incompatible(let missing):
            return .unusable(detail: "Missing flags: \(missing.joined(separator: ", "))")
        case .unverified(let detail): return .unusable(detail: "Couldn't verify: \(detail)")
        case .launchFailed(let message): return .unusable(detail: "Couldn't launch: \(message)")
        }
    }

    /// Every row, in the order the panel shows them: what a rip needs first,
    /// then what menu intelligence needs.
    ///
    /// - Parameters:
    ///   - dependencies: the helper's own `--check` report. `nil` means the
    ///     helper could not be run, which is why the two library rows then
    ///     read `.checking` rather than `.missing` — a helper that never ran
    ///     proves nothing about what is installed.
    static func rows(
        handbrake: ToolState?,
        makemkvcon: ToolState?,
        menudump: ToolState?,
        ffmpeg: ToolState?,
        lsdvdInstalled: Bool,
        dependencies: MenuDependencies?
    ) -> [Row] {
        var rows: [Row] = []

        rows.append(Row(
            name: "HandBrakeCLI",
            role: .required,
            status: status(handbrake),
            purpose: "Scans the disc and encodes the movie.",
            install: handbrakeInstall
        ))
        rows.append(Row(
            name: "makemkvcon",
            role: .optional,
            status: status(makemkvcon),
            purpose: "Fallback ripper for a disc HandBrake cannot read.",
            install: makemkvconInstall
        ))
        rows.append(Row(
            name: "lsdvd",
            role: .optional,
            status: lsdvdInstalled ? .installed(detail: nil) : .missing,
            purpose: "Identifies a disc so a selection survives a swap.",
            install: lsdvdInstall
        ))
        rows.append(Row(
            name: "changeover-menudump",
            role: .optional,
            status: status(menudump),
            purpose: "Reads the disc's menus: buttons, chapter pages, languages.",
            install: menudumpInstall
        ))
        rows.append(Row(
            name: "ffmpeg",
            role: .optional,
            status: status(ffmpeg),
            purpose: "Renders one still per menu so the text can be read, and upgrades an existing import's metadata.",
            install: ffmpegInstall
        ))

        rows.append(libraryRow(
            name: "libdvdread",
            purpose: "Decrypts menu video. Buttons and targets are read without it.",
            library: dependencies?.libdvdread,
            reportPresent: dependencies != nil,
            fallbackInstall: libdvdreadInstall
        ))
        rows.append(libraryRow(
            name: "libdvdcss",
            purpose: "The CSS key library the menu video needs.",
            library: dependencies?.libdvdcss,
            reportPresent: dependencies != nil,
            fallbackInstall: libdvdcssInstall
        ))

        return rows
    }

    private static func libraryRow(
        name: String,
        purpose: String,
        library: MenuDependencies.Library?,
        reportPresent: Bool,
        fallbackInstall: String
    ) -> Row {
        let status: Status
        if !reportPresent {
            // No report: the helper did not run. Absence of evidence.
            status = .checking
        } else if let library, library.isAvailable {
            status = .installed(detail: library.path)
        } else {
            status = .missing
        }
        return Row(
            name: name,
            role: .optional,
            status: status,
            purpose: purpose,
            install: library?.install ?? fallbackInstall
        )
    }

    /// The one-line summary above the table. Names what is missing rather
    /// than how many, because the whole point of the panel is the `brew`
    /// line that follows.
    static func summary(_ rows: [Row]) -> String {
        let missingRequired = rows.filter { $0.role == .required && $0.isMissing }
        if !missingRequired.isEmpty {
            return "\(missingRequired.map(\.name).joined(separator: ", ")) is required and not installed — no rip can run until it is."
        }
        let missingOptional = rows.filter { $0.role == .optional && $0.isMissing }
        if missingOptional.isEmpty {
            return "Everything Changeover can use is installed."
        }
        return "Optional, not installed: \(missingOptional.map(\.name).joined(separator: ", ")). Each one adds something; none is needed to rip a disc."
    }

    /// `docs/plain-language-ui.md` §3.16 — the one readiness line at the top
    /// of Settings, in the plain register.
    ///
    /// `nil` in the two cases where the honest answer is silence: while a
    /// required probe is still running (a "not installed" that turns into
    /// "ready" a second later is worse than nothing), and when only optional
    /// tools are missing — which is a fully supported Mac, and the person did
    /// not ask. `summary(_:)` above keeps naming them, verbatim, in Details.
    ///
    /// The failing line deliberately does not name HandBrake, even though
    /// the plan's draft did: the forbidden-terms rule (§1.2) has exactly two
    /// exemptions and this is not one of them, and the `brew` line the
    /// person actually needs is in Details with the tool's own name beside
    /// it.
    static func plainSummary(_ rows: [Row]) -> String? {
        let required = rows.filter { $0.role == .required }
        let stillChecking = required.contains { if case .checking = $0.status { return true } else { return false } }
        guard !stillChecking else { return nil }

        let unusable = required.contains { row in
            if case .installed = row.status { return false }
            return true
        }
        guard !unusable else {
            return "✗ A program Changeover needs isn't installed, so nothing can be ripped yet. Open Details for the command that installs it."
        }
        return "✓ Ready to rip."
    }
}
