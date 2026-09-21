import Foundation
import Testing
@testable import Changeover

/// The archive is the thing that turns a disc into evidence, so what it keeps
/// and what it drops is asserted rather than assumed.
///
/// The defect behind these tests: five discs were ripped on 19–20 September
/// and left nothing behind, because the menu read deleted its whole working
/// directory once the text was out of it. Four of them produced no chapter
/// names, and there was no way afterwards to tell a disc that prints none
/// from a reader that failed.
struct MenuArchiveTests {

    static func scratch() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("menu-archive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    // MARK: - Naming

    /// The disc id is preferred because it is stable across re-reads: the same
    /// pressing archives to the same directory whether it went in for a rip or
    /// for an upgrade, so a second capture improves the first rather than
    /// making a rival copy.
    @Test func theDiscIDNamesTheDirectoryWhenThereIsOne() {
        #expect(MenuArchive.slug(discID: "8a2b1c", volumeName: "BLOODSPORT") == "8a2b1c")
        #expect(MenuArchive.slug(discID: nil, volumeName: "BLOODSPORT") == "bloodsport")
        #expect(MenuArchive.slug(discID: "", volumeName: "BLOODSPORT") == "bloodsport")
    }

    /// A volume name is whatever the author typed, and it becomes a path
    /// component. Nothing it contains may reach outside the archive root.
    @Test func aVolumeNameCannotEscapeTheArchiveRoot() {
        #expect(MenuArchive.slug(discID: nil, volumeName: "../../etc") == "etc")
        #expect(MenuArchive.slug(discID: nil, volumeName: "BLOODSPORT/2") == "bloodsport-2")
        #expect(MenuArchive.slug(discID: nil, volumeName: "..") == "disc")
        #expect(MenuArchive.slug(discID: nil, volumeName: "///") == "disc")
        #expect(MenuArchive.slug(discID: nil, volumeName: "") == "disc")

        for name in ["../../etc", "BLOODSPORT/2", "..", "///", ""] {
            let slug = MenuArchive.slug(discID: nil, volumeName: name)
            #expect(!slug.contains("/"), "a slug is one path component")
            #expect(!slug.contains(".."), "a slug never walks up")
        }
    }

    @Test func theLayoutIsOneDirectoryPerDisc() {
        let menus = MenuArchive.menusDirectory(root: "/archive", slug: "bloodsport")
        #expect(menus == "/archive/bloodsport/menus")
    }

    // MARK: - What is written

    @Test func theTextProductsAreKeptAndTheVideoIsNot() throws {
        let root = try Self.scratch()
        let work = try Self.scratch()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: work)
        }

        // What a real read leaves behind: the helper's JSON, its cells, and a
        // still per page.
        let cells = (work as NSString).appendingPathComponent("cells")
        try FileManager.default.createDirectory(atPath: cells, withIntermediateDirectories: true)
        try Data("not really a vob".utf8)
            .write(to: URL(fileURLWithPath: (cells as NSString).appendingPathComponent("vtsm-01-lu1-pgc2.vob")))
        for still in ["vtsm-01-lu1-pgc2", "vtsm-01-lu1-pgc2-cell2"] {
            try Data("not really a jpeg".utf8)
                .write(to: URL(fileURLWithPath: (work as NSString).appendingPathComponent("\(still).jpg")))
        }

        let ocr = MenuOCRDocument(
            format: "changeover-menu-ocr/1",
            engine: MenuOCRDocument.Engine(
                framework: "Vision", api: "VNRecognizeTextRequest", os: "test",
                level: "accurate", languageCorrection: false, languages: ["en"],
                customWords: 0, upscale: 1, minimumTextHeightFraction: 0.02
            ),
            note: nil,
            stills: [
                MenuOCRDocument.Still(
                    id: "vtsm-01-lu1-pgc2",
                    frame: MenuStructure.Frame(width: 720, height: 480, standard: "NTSC"),
                    note: nil,
                    observations: [
                        TextObservation(text: "A mentor: Tanaka", confidence: 1,
                                        rect: PixelRect(minX: 10, minY: 10, maxX: 200, maxY: 30)),
                    ]
                ),
                MenuOCRDocument.Still(
                    id: "vtsm-01-lu1-pgc2-cell2",
                    frame: MenuStructure.Frame(width: 720, height: 480, standard: "NTSC"),
                    note: nil,
                    observations: []
                ),
            ]
        )

        let written = MenuArchive.write(
            root: root,
            slug: "bloodsport",
            structureJSON: Data(#"{"format":"changeover-menu-structure/1"}"#.utf8),
            ocr: ocr,
            derived: nil,
            stillIDs: ocr.stills.map { $0.id },
            workDirectory: work
        )
        #expect(written == "\(root)/bloodsport/menus")

        let menus = MenuArchive.menusDirectory(root: root, slug: "bloodsport")
        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: (menus as NSString).appendingPathComponent(relative))
        }
        #expect(exists("structure.json"))
        #expect(exists("ocr.json"))
        #expect(exists("stills/vtsm-01-lu1-pgc2.jpg"))
        #expect(exists("stills/vtsm-01-lu1-pgc2-cell2.jpg"), "every page's picture, not just the first")
        #expect(!exists("derived.json"), "a document that was not produced is absent, not empty")

        // The text round-trips: the point of keeping it is reading it later.
        let data = try Data(contentsOf: URL(fileURLWithPath: (menus as NSString).appendingPathComponent("ocr.json")))
        let reread = try JSONDecoder().decode(MenuOCRDocument.self, from: data)
        #expect(reread.stills.count == 2)
        #expect(reread.stills.first?.observations.first?.text == "A mentor: Tanaka")
    }

    /// The megabytes are the cells, and they are the one thing that can always
    /// be produced again from the disc the user still owns.
    @Test func theCellsAreTheDisposablePart() {
        let disposable = MenuArchive.disposable(in: "/work/abc")
        #expect(disposable == ["/work/abc/cells"])
    }

    /// An archive root that cannot be written must cost a rip nothing.
    @Test func anUnwritableArchiveRootIsNotAFailure() {
        let written = MenuArchive.write(
            root: "/dev/null/cannot-exist",
            slug: "bloodsport",
            structureJSON: Data("{}".utf8),
            ocr: nil,
            derived: nil,
            stillIDs: [],
            workDirectory: "/tmp"
        )
        #expect(written == nil)
    }
}
