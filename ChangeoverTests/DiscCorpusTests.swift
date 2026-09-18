import Foundation
import Testing
@testable import Changeover

/// #0055 — walks every captured real disc under `Fixtures/discs/<slug>/` and
/// asserts its recorded expectations. One parameterized test function: a
/// disc captured with `Tools/capture-disc.sh` and reviewed by a human adds
/// coverage with no new test code, and a regression in the parser, the
/// `DiscTitleHeuristic` (including the Play All guard), `AudioTrackOptions`
/// dedup or `SubtitleGrouping` fails here against real disc data, not just
/// synthetic fixtures shaped to the algorithm.
///
/// Each `Fixtures/discs/<slug>/` directory holds:
///   - `scan.json` — HandBrakeCLI's **stdout** from
///     `--scan --title 0 --min-duration 1 --json` (never a merged
///     stdout+stderr capture — #0039 found that splices HandBrake's log text
///     into the JSON and silently corrupts it).
///   - `scan.stderr.txt` — the same run's stderr, on its own file. Absent on
///     the three fixtures migrated into this layout (they predate the
///     two-file discipline `Tools/capture-disc.sh` now enforces); every new
///     capture writes one, but nothing here reads it — `DiscScanner`, not
///     this corpus, is what exercises stderr-derived warnings.
///   - `disc.json` — metadata plus the `DiscManifest.Expectation` this test
///     asserts. `reviewed` must be `true`, or the disc is refused rather
///     than silently skipped (see `discSlugs()`).
///
/// `discs/oppenheimer/scan.merged.txt` is the deliberate merged-capture
/// **negative** fixture for #0039 — it must fail to decode. It carries no
/// `disc.json` of its own, so `discSlugs()` never picks it up; it stays
/// covered by its own case in `HandBrakeScanParserTests`.
struct DiscCorpusTests {

    // MARK: - Manifest shape

    struct DiscManifest: Codable {
        struct Expectation: Codable {
            var titleCount: Int
            var mainFeatureIndex: Int?
            /// "single" | "playAll" | "none" | "noTitles" — the four
            /// `DiscTitleHeuristic.Outcome` cases, spelled as strings so the
            /// manifest stays plain JSON a capture script can write.
            var outcome: String
            /// The `.single`/`.playAll` title index. `nil` for `.none`/`.noTitles`.
            var outcomeIndex: Int?
            /// The `.playAll` episode cluster, in ascending order. `nil` otherwise.
            var outcomeEpisodes: [Int]?
            var featureDurationSeconds: Int?
            var featureChapterCount: Int?
            /// `AudioTrackOptions.options(for:).count` on the feature title.
            var audioTrackCount: Int?
            /// `SubtitleGrouping.groups(for:).count` on the feature title.
            var subtitleGroupCount: Int?
            /// Menu intelligence (`docs/menu-intelligence.md` §8.4).
            /// `nil` on a disc captured without its menus — the menu
            /// assertions are then skipped **by name**, never vacuously.
            var menu: MenuExpectation?
        }

        /// What the disc's own menus should yield. Every field is optional
        /// because the capture is built up incrementally: a disc read before
        /// `Tools/menudump` existed has OCR but no structure, and a host
        /// with no `libdvdcss` has structure but no stills. A field that is
        /// `nil` is not asserted, and the coverage test below says out loud
        /// which discs are carrying which half.
        struct MenuExpectation: Codable {
            /// The VMG title the disc's play button starts. This is the
            /// headline invariant: on a `single` disc it must equal
            /// `outcomeIndex`.
            var playButtonTitle: Int?
            var playButtonLabel: String?
            var playButtonResolvedBy: String?
            var chapterMenuButtons: Int?
            var chapterNamesEmitted: Int?
            /// Which stills are the scene-selection pages. Read off the
            /// structure's entry types when there is one; listed here for a
            /// capture that predates the helper.
            var chapterPages: [String]?
            var chapterNames: [String]?
            var languagesStill: String?
            var languageShape: String?
            var spokenLanguages: [String]?
            var subtitleLanguages: [String]?
            var entryStills: [String]?
            /// Stills that are *not* entry menus — the cast-and-crew and
            /// copyright pages §6's filmography trap lives on.
            var nonEntryStills: [String]?
            var titleTextCandidate: String?
            var titleTextOffered: Bool?
            var tvSignal: Bool?
            /// Mnemonics of entry-menu commands this build cannot resolve.
            /// A disc with genuinely opaque authoring lists them here and
            /// stays honest; a decoder regression shows up as an entry-menu
            /// button that resolves to nothing and is not listed.
            var unresolvedMnemonics: [String]?
            var notes: String?
        }

        /// How the capture was made (§8.4). Absent on version-1 manifests.
        struct Capture: Codable {
            var tool: String?
            var toolVersion: Int?
            var hostOS: String?
            var ffmpeg: String?
            var ifoFiles: Int?
            var rawArchive: String?
        }

        /// What the menu half of the capture produced (§8.4).
        struct Menus: Codable {
            var captured: Bool
            /// `false` on a capture that has stills but no
            /// `menus/structure.json` — the pre-helper shape.
            var structure: Bool?
            var css: String?
            var menuCount: Int?
            var stillCount: Int?
            var ocrRun: Bool?
            var judgeRun: Bool?
            var missing: [String]?
        }

        /// Absent means 1 (the discs captured before menu intelligence).
        /// A format change is a re-capture, never a migration.
        var formatVersion: Int?
        var slug: String
        var volumeName: String
        var driveName: String
        var discId: String?
        var driveModel: String?
        var handbrakeVersion: String?
        var capturedDate: String
        /// A human must confirm `expect` (especially `outcome` and the two
        /// dedup counts, which `Tools/capture-disc.sh` cannot compute on its
        /// own) before this disc is trusted. An unreviewed manifest fails
        /// its corpus case rather than being silently skipped.
        var reviewed: Bool
        var notes: String?
        var capture: Capture?
        var menus: Menus?
        var expect: Expectation
    }

    // MARK: - Corpus discovery

    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs")
    }

    /// Every subdirectory of `Fixtures/discs/` that has both `scan.json` and
    /// `disc.json` — exactly the shape `Tools/capture-disc.sh` produces.
    /// `oppenheimer`'s `scan.merged.txt` sits next to a real `disc.json`
    /// there but is a plain file, not a directory, so it is never itself
    /// picked up as a slug.
    private static func discSlugs() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: fixturesRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries
            .filter { url in
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return false
                }
                return fm.fileExists(atPath: url.appendingPathComponent("scan.json").path)
                    && fm.fileExists(atPath: url.appendingPathComponent("disc.json").path)
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Every subdirectory of `Fixtures/discs/`, whether or not it is a
    /// complete corpus disc — the denominator `discSlugs()` is checked
    /// against, so a capture that lost (or never got) its `disc.json` is
    /// named out loud instead of quietly dropping out of the sweep.
    private static func allDiscDirectories() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: fixturesRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries
            .filter { url in
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    private static func loadManifest(_ slug: String) throws -> DiscManifest {
        let data = try Data(contentsOf: fixturesRoot.appendingPathComponent(slug).appendingPathComponent("disc.json"))
        return try JSONDecoder().decode(DiscManifest.self, from: data)
    }

    private static func loadScanText(_ slug: String) throws -> String {
        try String(
            contentsOf: fixturesRoot.appendingPathComponent(slug).appendingPathComponent("scan.json"),
            encoding: .utf8
        )
    }

    /// Discovery must not silently pass with zero cases — a broken
    /// `fixturesRoot` path or a corpus that lost its `disc.json`s would
    /// otherwise leave `discMatchesItsRecordedExpectations` reporting a
    /// vacuous, all-green empty sweep. Pin the three discs this ticket
    /// migrates/adds as a floor, not a ceiling.
    @Test func corpusHasAtLeastTheThreeFoundingDiscs() {
        let slugs = Self.discSlugs()
        #expect(Set(["dragon-tattoo", "oppenheimer", "tv-season-playall"]).isSubset(of: Set(slugs)))
        #expect(slugs.count >= 3)
    }

    /// The other half of the same guard: `discSlugs()` only picks up a
    /// directory that has **both** `scan.json` and `disc.json`, so a capture
    /// committed without its manifest — or one whose manifest was deleted —
    /// would drop out of the sweep entirely and take its coverage with it,
    /// with nothing red to show for it. Name the offender instead.
    @Test func everyCapturedDiscDirectoryIsACompleteCorpusDisc() {
        let missing = Set(Self.allDiscDirectories()).subtracting(Self.discSlugs())
        #expect(
            missing.isEmpty,
            "Fixtures/discs/ holds \(missing.sorted()) without both scan.json and disc.json, so they are silently excluded from the corpus sweep. Complete the capture (Tools/capture-disc.sh) or remove the directory."
        )
    }

    // MARK: - The sweep

    @Test(arguments: DiscCorpusTests.discSlugs())
    func discMatchesItsRecordedExpectations(slug: String) throws {
        let manifest = try Self.loadManifest(slug)
        #expect(manifest.slug == slug, "\(slug): disc.json's own slug field disagrees with its directory name")
        #expect(manifest.reviewed, "\(slug): disc.json is not reviewed — see Tools/capture-disc.sh's header comment")

        let text = try Self.loadScanText(slug)
        let output = HandBrakeScanParser.parse(text, volumeName: manifest.volumeName, driveName: manifest.driveName)
        #expect(!output.titleSetCorrupted, "\(slug): scan.json failed to decode")
        #expect(output.disc.titles.count == manifest.expect.titleCount, "\(slug): title count")
        #expect(output.mainFeatureIndex == manifest.expect.mainFeatureIndex, "\(slug): MainFeature")

        let outcome = DiscTitleHeuristic.classify(output.disc, mainFeatureIndex: output.mainFeatureIndex)
        Self.assertOutcome(outcome, matches: manifest.expect, slug: slug)

        guard let featureIndex = manifest.expect.outcomeIndex,
              let feature = output.disc.titles.first(where: { $0.index == featureIndex }) else {
            return // .none / .noTitles discs have no feature title to check further.
        }

        if let expected = manifest.expect.featureDurationSeconds {
            #expect(feature.durationSeconds == expected, "\(slug): feature duration")
        }
        if let expected = manifest.expect.featureChapterCount {
            #expect(feature.chapterCount == expected, "\(slug): feature chapter count")
        }
        if let expected = manifest.expect.audioTrackCount {
            #expect(AudioTrackOptions.options(for: feature).count == expected, "\(slug): audio track count")
        }
        if let expected = manifest.expect.subtitleGroupCount {
            #expect(SubtitleGrouping.groups(for: feature).count == expected, "\(slug): subtitle group count")
        }
    }

    // MARK: - Menu intelligence (docs/menu-intelligence.md §8.6)

    private static func discDirectory(_ slug: String) -> URL {
        fixturesRoot.appendingPathComponent(slug)
    }

    /// Discs with a `menus/` directory. Menu capture is incremental: a disc
    /// is read when it next passes through the drive for its own rip, never
    /// on a special trip, so this list grows one disc at a time.
    private static func discsWithMenus() -> [String] {
        discSlugs().filter {
            FileManager.default.fileExists(atPath: discDirectory($0).appendingPathComponent("menus").path)
        }
    }

    private static func loadStructure(_ slug: String) throws -> MenuStructure? {
        let url = discDirectory(slug).appendingPathComponent("menus/structure.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try MenuStructure.decode(data)
    }

    private static func loadOCR(_ slug: String) throws -> MenuOCRDocument? {
        let url = discDirectory(slug).appendingPathComponent("menus/ocr.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try MenuOCRDocument.decode(data)
    }

    /// A version-2 manifest with no `menus` block is a **capture bug**, not
    /// "this disc has no menus" — the two are different and the sweep must
    /// not let the first pass as the second.
    @Test func everyVersionTwoManifestDeclaresItsMenuCapture() throws {
        for slug in Self.discSlugs() {
            let manifest = try Self.loadManifest(slug)
            guard (manifest.formatVersion ?? 1) >= 2 else { continue }
            #expect(
                manifest.menus != nil,
                "\(slug): disc.json is formatVersion \(manifest.formatVersion!) but has no `menus` block. That is a capture bug — re-run Tools/capture-disc.sh."
            )
        }
    }

    /// The other direction: a manifest that claims a menu capture must have
    /// the files, and one that has the files must claim them. Either
    /// mismatch silently removes a disc from the menu sweep.
    @Test func menuClaimsAndMenuFilesAgree() throws {
        for slug in Self.discSlugs() {
            let manifest = try Self.loadManifest(slug)
            let hasDirectory = FileManager.default.fileExists(
                atPath: Self.discDirectory(slug).appendingPathComponent("menus").path
            )
            #expect(
                (manifest.menus?.captured ?? false) == hasDirectory,
                "\(slug): disc.json says menus.captured = \(manifest.menus?.captured as Any) but menus/ \(hasDirectory ? "exists" : "does not exist")"
            )
            if manifest.menus?.structure == true || (hasDirectory && manifest.expect.menu?.playButtonTitle != nil) {
                #expect(
                    try Self.loadStructure(slug) != nil,
                    "\(slug): the manifest asserts tier-1 expectations but there is no menus/structure.json to derive them from"
                )
            }
        }
    }

    @Test(arguments: DiscCorpusTests.discsWithMenus())
    func discMenusMatchTheirRecordedExpectations(slug: String) throws {
        let manifest = try Self.loadManifest(slug)
        let expect = try #require(
            manifest.expect.menu,
            "\(slug): has a menus/ directory but no expect.menu — Tools/capture-disc.sh writes one; fill it in and review it."
        )
        let structure = try Self.loadStructure(slug)
        let ocr = try Self.loadOCR(slug)

        let scan = HandBrakeScanParser.parse(
            try Self.loadScanText(slug),
            volumeName: manifest.volumeName,
            driveName: manifest.driveName
        )

        // ---- tier 1, only where a structure was captured
        if let structure {
            Self.assertTheCaptureActuallyReadButtons(structure, slug: slug)
            try Self.assertTitleTableAgreesWithLsdvd(structure, slug: slug)
            try Self.assertStructureIsWellFormed(structure, slug: slug)
            try Self.assertTargetsExistInTheScan(structure, scan: scan, expect: expect, slug: slug)
            try Self.assertPlayButton(structure, manifest: manifest, expect: expect, slug: slug)

            if let expected = expect.tvSignal {
                #expect(MenuTVSignal.evaluate(structure).value == expected, "\(slug): tvSignal")
            }
            if let expected = expect.chapterMenuButtons {
                let count = structure.resolvedButtons().filter {
                    if case .chapter = $0.target { return true } else { return false }
                }.count
                #expect(count == expected, "\(slug): chapter-menu button count")
            }
        }

        // ---- tier 2, only where OCR ran
        guard let ocr else { return }
        try Self.assertChapterNames(ocr, structure: structure, expect: expect, slug: slug)
        Self.assertLanguageLists(ocr, expect: expect, slug: slug)
        Self.assertTitleTextAvoidsTheFilmographyTrap(ocr, expect: expect, slug: slug)
    }

    /// The slice of `lsdvd -x -Oj` this corpus reads: its own title table,
    /// which it builds with `libdvdread`.
    ///
    /// It is here to be a **second witness**. `Tools/menudump` parses the
    /// VMG title table (`TT_SRPT`) out of `VIDEO_TS.IFO` with its own code
    /// and no library, and everything tier 1 claims rests on that table
    /// meaning what it is believed to mean. Checking it against a different
    /// program's reading of the same bytes is the only way to find out
    /// without a disc — and on Bloodsport the two agree on all six titles,
    /// their title sets, their in-set numbers and their chapter counts.
    struct LsdvdDocument: Codable {
        struct Track: Codable {
            var ix: Int
            var vts: Int
            var ttn: Int
            var chapter: [Chapter]?
            struct Chapter: Codable { var ix: Int? }
        }
        /// The disc identity `DVDMonitor` debounces on. Spelled
        /// `dvddiscid`, not `discid` — the capture script guessed the
        /// shorter name and recorded `null` on every disc until this
        /// fixture showed the real key.
        var dvddiscid: String?
        var track: [Track]
    }

    private static func loadLsdvd(_ slug: String) throws -> LsdvdDocument? {
        let url = discDirectory(slug).appendingPathComponent("lsdvd.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(LsdvdDocument.self, from: data)
    }

    /// The manifest's `discId` is the one in the disc's own `lsdvd.json`.
    /// A capture that silently recorded `null` while the answer was sitting
    /// in the file next to it is the failure this pins.
    @Test func recordedDiscIdsMatchTheCapturedLsdvdOutput() throws {
        var checked = 0
        for slug in Self.discSlugs() {
            guard let lsdvd = try Self.loadLsdvd(slug), let id = lsdvd.dvddiscid else { continue }
            let manifest = try Self.loadManifest(slug)
            #expect(manifest.discId == id, "\(slug): disc.json records discId \(manifest.discId ?? "null") but lsdvd.json says \(id)")
            checked += 1
        }
        #expect(checked >= 1, "no disc in the corpus has a committed lsdvd.json — this check is asserting nothing")
    }

    /// `TT_SRPT`, read two ways. The helper's table and `lsdvd`'s must agree
    /// on every title: same count, same title set, same in-set number, same
    /// chapter count. A slip in the helper's IFO arithmetic shows up here
    /// against a program that was not written from the same notes.
    private static func assertTitleTableAgreesWithLsdvd(
        _ structure: MenuStructure,
        slug: String
    ) throws {
        guard let lsdvd = try loadLsdvd(slug), let titles = structure.titles else { return }
        #expect(titles.count == lsdvd.track.count, "\(slug): TT_SRPT has \(titles.count) titles, lsdvd sees \(lsdvd.track.count)")
        for track in lsdvd.track {
            guard let title = titles.first(where: { $0.title == track.ix }) else {
                Issue.record("\(slug): lsdvd lists title \(track.ix) and the helper's TT_SRPT does not")
                continue
            }
            #expect(title.vts == track.vts, "\(slug): title \(track.ix) title set")
            #expect(title.vtsTTN == track.ttn, "\(slug): title \(track.ix) in-set number")
            if let chapters = track.chapter {
                #expect(title.ptts == chapters.count, "\(slug): title \(track.ix) chapter count")
            }
        }
    }

    /// **The invariant this sweep was missing.**
    ///
    /// The first helper read 29 menu PGCs off Bloodsport and zero buttons —
    /// a four-byte slip in the PCI structure put every highlight field
    /// inside the next one — and the corpus sweep passed, because every
    /// assertion it had was conditional on an `expect.menu` field that a
    /// capture with no buttons never fills in. A reader that returns nothing
    /// satisfies every check that only looks at what it returned.
    ///
    /// So: a menu PGC with cells has video, and video means a NAV pack. If
    /// *no* menu on the whole disc yields a button, the capture is broken,
    /// not the disc — no DVD ships menus you cannot press. This is asserted
    /// for the disc as a whole rather than per menu, because individual
    /// PGCs legitimately have none (Bloodsport's own orphaned PGCs do).
    private static func assertTheCaptureActuallyReadButtons(_ structure: MenuStructure, slug: String) {
        let withCells = structure.menus.filter(\.hasCells)
        guard !withCells.isEmpty else { return }
        let withButtons = withCells.filter { !$0.buttons.isEmpty }
        #expect(
            !withButtons.isEmpty,
            "\(slug): \(withCells.count) menu PGCs have cells and not one of them yielded a button. That is a broken reader, not a disc without menus — check menus/structure.json's nav.error and nav.lbnMatches."
        )

        // The reader's own self-checks, published in the capture. lbnMatches
        // compares the sector address the *disc* wrote into the pack with
        // the sector the IFO sent us to, so it fails independently of any
        // assumption the parser makes about where fields sit.
        for menu in withCells {
            guard let nav = menu.nav else { continue }
            if !menu.buttons.isEmpty {
                #expect(nav.lbnMatches == true, "\(slug)/\(menu.id): the NAV pack's own sector address does not match the sector the IFO named — the PCI data offset is wrong")
                #expect(nav.rectsInsideFrame == true, "\(slug)/\(menu.id): button rectangles fall outside the frame")
                #expect(nav.groupsAgree == true, "\(slug)/\(menu.id): the button groups carry different commands, so taking group 1 is losing information")
                #expect(nav.error == nil, "\(slug)/\(menu.id): \(nav.error ?? "")")
            }
        }
    }

    private static func assertStructureIsWellFormed(_ structure: MenuStructure, slug: String) throws {
        let frame = try #require(structure.frame, "\(slug): structure.json has no frame size")
        for menu in structure.menus {
            #expect(menu.buttons.count <= 36, "\(slug)/\(menu.id): a DVD menu holds at most 36 buttons")
            for button in menu.buttons {
                #expect(button.command.count == 16, "\(slug)/\(menu.id)#\(button.number): command is not 16 hex characters")
                #expect(VMCommand(hex: button.command) != nil, "\(slug)/\(menu.id)#\(button.number): command is not hex")
                #expect(
                    button.rect.minX >= 0 && button.rect.maxX <= frame.width
                        && button.rect.minY >= 0 && button.rect.maxY <= frame.height,
                    "\(slug)/\(menu.id)#\(button.number): rect \(button.rect) is outside the \(frame.width)x\(frame.height) frame"
                )
            }
        }
    }

    /// Every button on an entry menu either resolves, or its mnemonic is
    /// recorded in the manifest. A decoder regression shows up here as an
    /// unlisted mnemonic; a disc with GPRM-driven authoring stays honest by
    /// listing its own.
    private static func assertTargetsExistInTheScan(
        _ structure: MenuStructure,
        scan: HandBrakeScanParser.Output,
        expect: DiscManifest.MenuExpectation,
        slug: String
    ) throws {
        let allowed = Set(expect.unresolvedMnemonics ?? [])
        for button in structure.resolvedButtons() where button.onEntryMenu {
            if case .unresolved(let mnemonic) = button.target {
                #expect(
                    allowed.contains(mnemonic),
                    "\(slug)/\(button.ref.menu)#\(button.ref.number): \(mnemonic) did not resolve and is not in expect.menu.unresolvedMnemonics"
                )
            }
        }

        // HandBrake drops sub-second stubs with --min-duration 1, so a menu
        // may legitimately point at a title the scan does not list. The
        // check is therefore a subset check with the shortfall named.
        let scanTitles = Set(scan.disc.titles.map(\.index))
        let unmatched = structure.resolvedButtons()
            .compactMap { $0.target.titleNumber }
            .filter { !scanTitles.contains($0) }
        #expect(
            unmatched.isEmpty,
            "\(slug): buttons jump to titles \(Set(unmatched).sorted()) that scan.json does not list (it lists \(scanTitles.sorted()))"
        )
    }

    /// **The headline invariant.** `JumpTT n` names the n-th entry of the
    /// VMG title table; libhb indexes the same table for its title n. The
    /// claim that those two numberings agree is what makes every caption in
    /// §4.1 worth showing, and it is proved — or disproved — here, disc by
    /// disc, against the disc's own play button.
    private static func assertPlayButton(
        _ structure: MenuStructure,
        manifest: DiscManifest,
        expect: DiscManifest.MenuExpectation,
        slug: String
    ) throws {
        var labels: [MenuButtonRef: String] = [:]
        if let ocr = try loadOCR(slug) {
            for menu in structure.menus {
                let buttons = structure.resolvedButtons().filter { $0.ref.menu == menu.id }
                for still in menu.stills ?? [menu.id] {
                    guard let observations = ocr.still(still)?.observations else { continue }
                    for (ref, label) in PlayButtonResolver.labels(buttons: buttons, observations: observations) {
                        labels[ref] = label
                    }
                }
            }
        }

        let resolution = PlayButtonResolver.resolve(structure, labels: labels)
        guard let expectedTitle = expect.playButtonTitle else {
            return // this capture makes no tier-1 claim
        }
        let resolved = try #require(resolution, "\(slug): expect.menu.playButtonTitle is \(expectedTitle) but no play button resolved")
        #expect(resolved.title == expectedTitle, "\(slug): play button target")
        if let label = expect.playButtonLabel {
            #expect(resolved.label == label, "\(slug): play button label")
        }
        if let resolvedBy = expect.playButtonResolvedBy {
            #expect(resolved.resolvedBy.rawValue == resolvedBy, "\(slug): play button resolution rung")
        }

        // The invariant itself: the disc's own Play button and the scan's
        // feature must be the same title.
        if manifest.expect.outcome == "single" || manifest.expect.outcome == "playAll",
           let outcomeIndex = manifest.expect.outcomeIndex {
            #expect(
                resolved.title == outcomeIndex,
                "\(slug): the disc's play button starts title \(resolved.title) but the scan's outcome index is \(outcomeIndex). If this is real, the caption in §4.1 is the disagree form; if it is a numbering bug, JumpTT and HandBrake's title index do not agree and every menu caption has to be disabled."
            )
        }
    }

    private static func assertChapterNames(
        _ ocr: MenuOCRDocument,
        structure: MenuStructure?,
        expect: DiscManifest.MenuExpectation,
        slug: String
    ) throws {
        guard let expectedRows = expect.chapterNamesEmitted else { return }
        let pages = expect.chapterPages
            ?? structure?.menus.filter(\.isChapterMenu).flatMap { $0.stills ?? [$0.id] }
            ?? []
        #expect(!pages.isEmpty, "\(slug): expect.menu.chapterNamesEmitted is set but no chapter pages are named")

        let candidates = ChapterNames.candidates(stills: pages.map { ocr.still($0)?.observations ?? [] })
        if let expectedNames = expect.chapterNames {
            #expect(
                candidates.sorted { $0.chapter < $1.chapter }.map(\.name) == expectedNames,
                "\(slug): chapter names read off the menu"
            )
        }

        let chapterCount = expect.chapterMenuButtons ?? expectedRows
        let rows = ChapterNames.markers(candidates, chapterCount: max(chapterCount, expectedRows))
        #expect(rows?.count == expectedRows, "\(slug): chapter CSV rows")
        guard let rows else { return }
        #expect(Set(rows.map(\.number)).count == rows.count, "\(slug): duplicate chapter numbers in the CSV")
        #expect(rows.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }, "\(slug): empty chapter name")
        #expect(rows.allSatisfy { $0.number >= 1 }, "\(slug): chapter number below 1")
    }

    private static func assertLanguageLists(
        _ ocr: MenuOCRDocument,
        expect: DiscManifest.MenuExpectation,
        slug: String
    ) {
        guard let still = expect.languagesStill, let observations = ocr.still(still)?.observations else { return }
        let lists = LanguageHints.lists(observations: observations)
        if let spoken = expect.spokenLanguages {
            #expect(lists.spoken == spoken, "\(slug): spoken languages from the menu")
        }
        if let subtitles = expect.subtitleLanguages {
            #expect(lists.subtitles == subtitles, "\(slug): subtitle languages from the menu")
        }
        if let shape = expect.languageShape {
            #expect(lists.shape.rawValue == shape, "\(slug): language menu shape")
        }
    }

    /// §6 rule 3, pinned by name. `Bloodsport (1987)` appears on five
    /// cast-and-crew pages and once, misread, on the title card. A search
    /// term taken from anywhere but an entry menu would pick a Van Damme
    /// film at random, so the candidate must never be a string that only a
    /// non-entry page carries.
    private static func assertTitleTextAvoidsTheFilmographyTrap(
        _ ocr: MenuOCRDocument,
        expect: DiscManifest.MenuExpectation,
        slug: String
    ) {
        guard let entryStills = expect.entryStills, !entryStills.isEmpty else { return }
        let candidate = MenuTitleGuess.candidate(
            entryStills: entryStills.map { id in
                MenuTitleGuess.EntryStill(id: id, observations: ocr.still(id)?.observations ?? [], buttons: [])
            }
        )
        if let expected = expect.titleTextCandidate {
            #expect(candidate?.text == expected, "\(slug): menu title-text candidate")
        }
        guard let candidate else { return }
        let nonEntryText = Set(
            (expect.nonEntryStills ?? [])
                .flatMap { ocr.still($0)?.observations ?? [] }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        #expect(
            !nonEntryText.contains(candidate.text),
            "\(slug): the title-text candidate \"\(candidate.text)\" also appears on a non-entry page — that is the filmography trap"
        )
        #expect(
            !MenuTitleGuess.looksLikeFilmographyCredit(candidate.text),
            "\(slug): the title-text candidate \"\(candidate.text)\" is a Title (Year) credit"
        )
    }

    private static func assertOutcome(
        _ outcome: DiscTitleHeuristic.Outcome,
        matches expect: DiscManifest.Expectation,
        slug: String
    ) {
        switch (expect.outcome, outcome) {
        case ("single", .single(let index, _)):
            #expect(index == expect.outcomeIndex, "\(slug): .single index")
        case ("playAll", .playAll(let index, let episodes)):
            #expect(index == expect.outcomeIndex, "\(slug): .playAll index")
            #expect(episodes == (expect.outcomeEpisodes ?? []), "\(slug): .playAll episode cluster")
        case ("none", .none):
            break
        case ("noTitles", .noTitles):
            break
        default:
            Issue.record("\(slug): disc.json expects outcome \"\(expect.outcome)\", classify returned \(outcome)")
        }
    }
}
