// menu-agreement — sweep the captured disc corpus and write the one place
// that says where the disc's own menu and the title heuristic agree
// (docs/menu-intelligence.md §8.6, §11.4).
//
// It links the app's own sources, so the report, the corpus sweep and the
// running app are produced by the same pure functions and cannot drift:
//
//   swiftc -O -o build/menu-agreement \
//     Changeover/DiscInfo.swift Changeover/HandBrakeScanParser.swift \
//     Changeover/DiscTitleHeuristic.swift Changeover/LanguageCode.swift \
//     Changeover/MenuStructure.swift Changeover/VMCommand.swift \
//     Changeover/MenuLexicon.swift Changeover/MenuOCR.swift \
//     Changeover/ChapterNames.swift Changeover/ChapterMarkerPlan.swift \
//     Changeover/LanguageHints.swift Changeover/MenuTitleGuess.swift \
//     Changeover/PlayButtonResolver.swift Changeover/MenuJudge.swift \
//     Changeover/MenuIntelligence.swift Changeover/MenuDerived.swift \
//     Changeover/MenuAgreement.swift Changeover/MenuAgreementReport.swift \
//     Changeover/DiscNameSearchTerm.swift \
//     Tools/menu-agreement/main.swift
//
//   build/menu-agreement --corpus ChangeoverTests/Fixtures/discs \
//                        [--out ChangeoverTests/Fixtures/discs/agreement-report.txt] \
//                        [--manifest <slug>]
//
// With `--out` it rewrites the committed report; without, it prints it.
// With `--manifest <slug>` it prints just that disc's `expect.agreement`
// block, ready to paste into its disc.json — which is how a freshly captured
// disc gets its recorded verdict.
//
// Nothing here reads or writes anything a rip depends on.

import Foundation

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let corpusPath = option("--corpus") ?? "ChangeoverTests/Fixtures/discs"
let corpus = URL(fileURLWithPath: corpusPath)

/// Only the manifest fields this tool needs. The corpus sweep decodes the
/// whole thing; here a narrow view keeps the tool independent of the test
/// target's `DiscManifest`.
struct ManifestHead: Decodable {
    struct Menus: Decodable { var captured: Bool }
    var slug: String
    var volumeName: String
    var driveName: String
    var menus: Menus?
}

let fm = FileManager.default
let slugs = ((try? fm.contentsOfDirectory(at: corpus, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
    .filter { url in
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return fm.fileExists(atPath: url.appendingPathComponent("scan.json").path)
            && fm.fileExists(atPath: url.appendingPathComponent("disc.json").path)
    }
    .map(\.lastPathComponent)
    .sorted()

guard !slugs.isEmpty else {
    FileHandle.standardError.write(Data("no discs under \(corpusPath)\n".utf8))
    exit(1)
}

var rows: [MenuAgreement] = []
for slug in slugs {
    let directory = corpus.appendingPathComponent(slug)
    guard let manifestData = try? Data(contentsOf: directory.appendingPathComponent("disc.json")),
          let manifest = try? JSONDecoder().decode(ManifestHead.self, from: manifestData),
          let scanText = try? String(contentsOf: directory.appendingPathComponent("scan.json"), encoding: .utf8)
    else {
        FileHandle.standardError.write(Data("\(slug): could not read scan.json or disc.json\n".utf8))
        continue
    }
    let scan = HandBrakeScanParser.parse(scanText, volumeName: manifest.volumeName, driveName: manifest.driveName)
    let structure = (try? Data(contentsOf: directory.appendingPathComponent("menus/structure.json")))
        .flatMap { try? MenuStructure.decode($0) }
    let ocr = (try? Data(contentsOf: directory.appendingPathComponent("menus/ocr.json")))
        .flatMap { try? MenuOCRDocument.decode($0) }
    rows.append(
        MenuAgreement.evaluate(
            slug: slug,
            disc: scan.disc,
            mainFeatureIndex: scan.mainFeatureIndex,
            structure: structure,
            ocr: ocr,
            menusCaptured: manifest.menus?.captured ?? fm.fileExists(atPath: directory.appendingPathComponent("menus").path)
        )
    )
}

let report = MenuAgreementReport.make(rows)

if let slug = option("--manifest") {
    guard let row = rows.first(where: { $0.slug == slug }) else {
        FileHandle.standardError.write(Data("no disc named \(slug)\n".utf8))
        exit(1)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(data: try encoder.encode(row), encoding: .utf8) ?? "{}")
    exit(0)
}

if let out = option("--out") {
    try report.text.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("wrote \(out)\n".utf8))
} else {
    print(report.text, terminator: "")
}
