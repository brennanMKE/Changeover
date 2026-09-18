// menu-derive — resolve tiers 1 and 2 over one disc's captured menus and
// write `menus/derived.json` (docs/menu-intelligence.md §8.3, §8.5 step 7).
//
// It links the app's own resolver sources, so the archive and the app are
// produced by the same functions and cannot drift apart:
//
//   swiftc -O -o build/menu-derive \
//     Changeover/MenuStructure.swift Changeover/VMCommand.swift \
//     Changeover/MenuLexicon.swift Changeover/MenuOCR.swift \
//     Changeover/ChapterNames.swift Changeover/LanguageHints.swift \
//     Changeover/MenuTitleGuess.swift Changeover/PlayButtonResolver.swift \
//     Changeover/MenuDerived.swift Changeover/DiscNameSearchTerm.swift \
//     Tools/menu-derive/main.swift
//
//   build/menu-derive --out menus/derived.json \
//                     [--structure menus/structure.json] [--ocr menus/ocr.json] \
//                     [--chapter-count 23] [--volume-name BLOODSPORT] \
//                     [--chapter-pages menu_05,menu_06] [--entry-stills menu_16] \
//                     [--languages-still menu_02]
//
// The `--*-stills` hints exist for captures made before Tools/menudump did:
// with a structure.json the pages are read off each menu PGC's entry type
// and the hints are ignored.

import Foundation

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func list(_ name: String) -> [String] {
    (option(name) ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

guard let outputPath = option("--out") else {
    FileHandle.standardError.write(Data("usage: menu-derive --out <derived.json> [--structure …] [--ocr …]\n".utf8))
    exit(2)
}

var structure: MenuStructure?
if let path = option("--structure"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
    structure = try? MenuStructure.decode(data)
}
var ocr: MenuOCRDocument?
if let path = option("--ocr"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
    ocr = try? MenuOCRDocument.decode(data)
}

let chapterCount = Int(option("--chapter-count") ?? "") ?? 0
let volumeName = option("--volume-name") ?? ""

// Which stills are which kind of page. The structure answers when it is
// there; otherwise the caller says so explicitly and the archive records
// which of the two happened.
func stillIDs(matching predicate: (MenuStructure.Menu) -> Bool, hint: String) -> [String] {
    if let structure {
        let ids = structure.menus.filter(predicate).flatMap { $0.stills ?? [$0.id] }
        if !ids.isEmpty { return ids }
    }
    return list(hint)
}

let chapterPages = stillIDs(matching: { $0.isChapterMenu }, hint: "--chapter-pages")
let entryStillIDs = stillIDs(matching: { $0.isEntryMenu }, hint: "--entry-stills")
let languageStills = stillIDs(matching: { $0.entryType == "audio" || $0.entryType == "subpicture" }, hint: "--languages-still")

func observations(_ id: String) -> [TextObservation] { ocr?.still(id)?.observations ?? [] }

// Tier 1: buttons and targets.
let resolved = structure?.resolvedButtons() ?? []
var labels: [MenuButtonRef: String] = [:]
if ocr != nil {
    for menu in structure?.menus ?? [] {
        let buttons = resolved.filter { $0.ref.menu == menu.id }
        let stills = menu.stills ?? [menu.id]
        for still in stills {
            for (ref, label) in PlayButtonResolver.labels(buttons: buttons, observations: observations(still)) {
                labels[ref] = label
            }
        }
    }
}

let playButton = structure.flatMap { PlayButtonResolver.resolve($0, labels: labels) }

// Tier 2: chapter names, one still at a time — geometry is per frame.
let chapterCandidates: [ChapterNames.Candidate]
if resolved.contains(where: { if case .chapter = $0.target { return true } else { return false } }) {
    chapterCandidates = chapterPages.flatMap { still in
        ChapterNames.candidates(
            buttons: resolved.filter { $0.ref.menu == still || (structure?.menus.first { $0.stills?.contains(still) ?? false }?.id == $0.ref.menu) },
            observations: observations(still)
        )
    }
} else {
    chapterCandidates = ChapterNames.candidates(stills: chapterPages.map(observations))
}
let markerRows = ChapterNames.markers(chapterCandidates, chapterCount: chapterCount)

// Tier 2: language lists.
var languages: LanguageHints.Lists?
for still in languageStills {
    let menuID = structure?.menus.first { ($0.stills ?? [$0.id]).contains(still) }?.id
    let lists = LanguageHints.lists(
        observations: observations(still),
        buttons: resolved.filter { $0.ref.menu == menuID }
    )
    if !lists.isEmpty { languages = lists; break }
}

// §6: a search term, only from entry menus and only when the volume name gave none.
let entryStills = entryStillIDs.map { id in
    MenuTitleGuess.EntryStill(
        id: id,
        observations: observations(id),
        buttons: resolved
            .filter { button in structure?.menus.first { ($0.stills ?? [$0.id]).contains(id) }?.id == button.ref.menu }
            .map(\.rect)
    )
}
let titleText = MenuTitleGuess.candidate(entryStills: entryStills)
let offered = !volumeName.isEmpty && DiscNameSearchTerm.derive(volumeName: volumeName) == nil && titleText != nil

let derived = MenuDerived(
    format: "changeover-menu-derived/1",
    resolver: MenuDerived.Resolver(app: "slice1", lexicon: MenuLexicon.playLabels.count),
    buttons: resolved.map { button in
        MenuDerived.ButtonRecord(
            menu: button.ref.menu,
            number: button.ref.number,
            target: button.target.archiveDescription,
            label: labels[button.ref],
            labelConfidence: nil
        )
    },
    playButton: playButton,
    chapterMenu: chapterPages.isEmpty ? nil : MenuDerived.ChapterMenu(
        title: playButton?.title,
        buttons: resolved.filter { if case .chapter = $0.target { return true } else { return false } }.count,
        pages: chapterPages,
        names: chapterCandidates.sorted { $0.chapter < $1.chapter },
        csvRows: markerRows?.count ?? 0
    ),
    languages: languages,
    tvSignal: structure.map(MenuTVSignal.evaluate)
        ?? MenuDerived.TVSignal(value: false, reason: "no structure.json captured"),
    titleText: titleText,
    judge: nil
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(derived).write(to: URL(fileURLWithPath: outputPath))

// The summary a human review reads first (§8.5 step 8).
print("menu-derive: wrote \(outputPath)")
print("  menus:          \(structure?.menus.count ?? 0)")
print("  buttons:        \(resolved.count)")
if let playButton {
    print("  play button:    \(playButton.menu)#\(playButton.number) \(playButton.label.map { "\"\($0)\"" } ?? "(no label)") -> title \(playButton.title) [\(playButton.resolvedBy.rawValue), \(playButton.candidates) candidate(s)]")
} else {
    print("  play button:    not resolved")
}
print("  chapter names:  \(markerRows?.count ?? 0) of \(chapterCount)\(markerRows == nil ? "  — REFUSED, bare --markers" : "")")
if let languages {
    print("  languages:      \(languages.shape.rawValue) spoken=\(languages.spoken) subtitles=\(languages.subtitles)")
}
print("  tv signal:      \(derived.tvSignal.value) (\(derived.tvSignal.reason))")
print("  title text:     \(titleText?.text ?? "none")\(offered ? " (offered)" : " (not offered)")")
let unresolved = Set(resolved.compactMap { button -> String? in
    if case .unresolved(let mnemonic) = button.target { return mnemonic }
    return nil
}).sorted()
print("  unresolved:     \(unresolved.isEmpty ? "none" : unresolved.joined(separator: ", "))")
