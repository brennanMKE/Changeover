// menu-ocr — read every menu still with Vision and write `menus/ocr.json`.
//
// Step 6 of `Tools/capture-disc.sh` (docs/menu-intelligence.md §8.5). It
// links the app's own `Changeover/MenuOCR.swift`, so the archive is produced
// by the same code the app runs and a change to the settings shows up in
// both places at once.
//
//   swiftc -O -o build/menu-ocr \
//     Changeover/MenuStructure.swift Changeover/MenuLexicon.swift \
//     Changeover/MenuOCR.swift Tools/menu-ocr/main.swift
//   build/menu-ocr out/ocr.json [--note "..."] stills/*.png
//
// The still id is the image's file stem, which is the menu PGC id once
// `Tools/menudump` has named the stills (`vtsm-01-lu1-pgc3`).

import Foundation
import AppKit
import Vision

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: menu-ocr <out.json> [--note <text>] <still.png>...\n".utf8))
    exit(2)
}

let outputPath = arguments[0]
var rest = Array(arguments.dropFirst())
var note: String? = nil
if let flag = rest.firstIndex(of: "--note"), flag + 1 < rest.count {
    note = rest[flag + 1]
    rest.removeSubrange(flag...(flag + 1))
}
let imagePaths = rest
let settings = MenuOCR.Settings()

var stills: [MenuOCRDocument.Still] = []
var failures = 0

for path in imagePaths {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write(Data("menu-ocr: could not load \(path)\n".utf8))
        failures += 1
        continue
    }
    let id = (path as NSString).lastPathComponent
    let stem = (id as NSString).deletingPathExtension
    do {
        let observations = try MenuOCR.observations(
            in: cg,
            frameWidth: cg.width,
            frameHeight: cg.height,
            settings: settings
        )
        stills.append(
            MenuOCRDocument.Still(
                id: stem,
                frame: MenuStructure.Frame(
                    width: cg.width,
                    height: cg.height,
                    standard: cg.height == 576 ? "PAL" : "NTSC"
                ),
                note: nil,
                observations: observations
            )
        )
        FileHandle.standardError.write(Data("menu-ocr: \(stem) — \(observations.count) observations\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("menu-ocr: \(stem) failed: \(error)\n".utf8))
        failures += 1
    }
}

let document = MenuOCRDocument(
    format: "changeover-menu-ocr/1",
    engine: MenuOCRDocument.Engine(
        framework: "Vision",
        api: "VNRecognizeTextRequest",
        os: ProcessInfo.processInfo.operatingSystemVersionString,
        level: "accurate",
        languageCorrection: settings.usesLanguageCorrection,
        languages: settings.languages,
        customWords: settings.customWords.count,
        upscale: settings.upscale,
        minimumTextHeightFraction: settings.minimumTextHeightFraction
    ),
    note: note,
    stills: stills.sorted { $0.id < $1.id }
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
do {
    try encoder.encode(document).write(to: URL(fileURLWithPath: outputPath))
    print("menu-ocr: wrote \(outputPath) (\(stills.count) stills, \(failures) failures)")
} catch {
    FileHandle.standardError.write(Data("menu-ocr: could not write \(outputPath): \(error)\n".utf8))
    exit(1)
}
exit(failures == 0 ? 0 : 1)
