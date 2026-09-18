import Foundation
import Testing
@testable import Changeover

/// Tier 1 over a whole `structure.json`: targets lifted through the title
/// table, the play button chosen, the TV signal, and the geometry that
/// attaches text to buttons.
///
/// The fixture is `Fixtures/menus/synthetic-movie/structure.json`, produced
/// by `Tools/menudump` reading a **synthetic** VIDEO_TS that
/// `Tools/menudump/make-test-disc.py` writes from the published table
/// layouts. It is not disc evidence and is never treated as such — real
/// discs are asserted in `DiscCorpusTests`. What it is good for is having
/// one of every command shape in one document, which no single real disc
/// offers.
struct MenuStructureTests {

    static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/menus")
    }

    static func load(_ slug: String) throws -> MenuStructure {
        try MenuStructure.decode(
            Data(contentsOf: fixturesRoot.appendingPathComponent(slug).appendingPathComponent("structure.json"))
        )
    }

    // MARK: - Decoding the document

    @Test func syntheticStructureDecodes() throws {
        let structure = try Self.load("synthetic-movie")
        #expect(structure.format == "changeover-menu-structure/1")
        #expect(structure.frame?.width == 720)
        #expect(structure.frame?.height == 480)
        #expect(structure.menus.count == 5)
        #expect(structure.titles?.first?.ptts == 23)
    }

    /// `menudump` reports what it could not find by formula name, so the app
    /// can tell "libdvdcss is not installed" from "this disc has no menus".
    /// The two must never look alike, because one is fixed with `brew
    /// install` and the other is not fixed at all.
    @Test func theHelperReportsItsMissingDependenciesByName() throws {
        let structure = try Self.load("synthetic-movie")
        let helper = try #require(structure.helper)
        #expect(helper.name == "changeover-menudump")
        // The synthetic capture ran on a Mac with no DVD tooling at all,
        // which is the point: tier 1 still produced a complete document.
        #expect(helper.missing?.contains("libdvdread") == true)
        #expect(helper.install?.contains("brew install libdvdread") == true)
        #expect(helper.css == "unavailable")
        #expect(!structure.menus.isEmpty, "no libdvdcss must still mean a full structure, just no stills")
    }

    // MARK: - Targets

    @Test func everyButtonOnAnEntryMenuResolves() throws {
        let structure = try Self.load("synthetic-movie")
        let entryButtons = structure.resolvedButtons().filter(\.onEntryMenu)
        #expect(entryButtons.count == 5)
        #expect(entryButtons.allSatisfy { !$0.target.isUnresolved })
    }

    /// `JumpVTS_PTT` names a title inside its own title set; only `TT_SRPT`
    /// turns that into the number HandBrake uses. Without the lift a chapter
    /// menu on VTS 2 would silently name VTS 1's chapters.
    @Test func vtsRelativeChaptersAreLiftedThroughTheTitleTable() throws {
        let structure = try Self.load("synthetic-movie")
        let chapters = structure.resolvedButtons()
            .filter { $0.ref.menu == "vtsm-01-lu1-pgc2" }
            .compactMap { button -> Int? in
                if case .chapter(let title, let ptt) = button.target, title == 1 { return ptt }
                return nil
            }
        #expect(chapters == [1, 2, 3, 4, 5, 6])
    }

    @Test func aStructureWithNoTitleTableKeepsTheVTSRelativeForm() throws {
        var structure = try Self.load("synthetic-movie")
        structure.titles = nil
        let targets = structure.resolvedButtons().filter { $0.ref.menu == "vtsm-01-lu1-pgc2" }.map(\.target)
        #expect(targets.first == .chapterInVTS(vts: 1, ttn: 1, ptt: 1))
    }

    @Test func rawCommandsSurviveAsSixteenHexCharacters() throws {
        let structure = try Self.load("synthetic-movie")
        for menu in structure.menus {
            for button in menu.buttons {
                #expect(button.command.count == 16, "\(menu.id)#\(button.number): \(button.command)")
                #expect(VMCommand(hex: button.command) != nil)
            }
        }
    }

    @Test func everyButtonRectangleLiesInsideTheFrame() throws {
        let structure = try Self.load("synthetic-movie")
        let frame = try #require(structure.frame)
        for menu in structure.menus {
            for button in menu.buttons {
                #expect(button.rect.minX >= 0 && button.rect.maxX <= frame.width, "\(menu.id)#\(button.number)")
                #expect(button.rect.minY >= 0 && button.rect.maxY <= frame.height, "\(menu.id)#\(button.number)")
                #expect(!button.rect.isEmpty)
            }
        }
    }

    // MARK: - The play button

    @Test func aLoneTitleJumpResolvesStructurally() throws {
        let structure = try Self.load("synthetic-movie")
        let resolution = try #require(PlayButtonResolver.resolve(structure))
        #expect(resolution.title == 1)
        #expect(resolution.resolvedBy == .structure)
        #expect(resolution.label == nil, "no OCR ran, so there is no label — and that is a caption, not a failure")
    }

    /// The headline invariant of `docs/menu-intelligence.md` §8.6, stated as
    /// a unit test so the *logic* is pinned here and the *discs* are pinned
    /// in `DiscCorpusTests`: what the disc's own play button starts must be
    /// the title the scan chose.
    @Test func thePlayButtonTargetIsTheFeatureTitle() throws {
        let structure = try Self.load("synthetic-movie")
        let resolution = try #require(PlayButtonResolver.resolve(structure))
        let scanFeatureTitle = 1     // the synthetic disc's only title
        #expect(resolution.title == scanFeatureTitle)
        #expect(
            PlayButtonResolver.confirmationLine(resolution, scanFeatureTitle: scanFeatureTitle)
                == "Disc menu: the Play button starts title 1 — matches."
        )
    }

    @Test func aDisagreementIsACaptionNotAnError() throws {
        let structure = try Self.load("synthetic-movie")
        let resolution = try #require(PlayButtonResolver.resolve(structure))
        #expect(
            PlayButtonResolver.confirmationLine(resolution, scanFeatureTitle: 3)
                == "Disc menu: the Play button starts title 1; the scan chose title 3."
        )
    }

    @Test func aLexiconHitNamesTheButton() throws {
        let structure = try Self.load("synthetic-movie")
        let labels = [
            MenuButtonRef(menu: "vtsm-01-lu1-pgc1", number: 1): "Play Movie",
            MenuButtonRef(menu: "vtsm-01-lu1-pgc1", number: 2): "Scene Selections",
        ]
        let resolution = try #require(PlayButtonResolver.resolve(structure, labels: labels))
        #expect(resolution.label == "Play Movie")
        #expect(
            PlayButtonResolver.confirmationLine(resolution, scanFeatureTitle: 1)
                == "Disc menu: \"Play Movie\" starts title 1 — matches."
        )
    }

    /// Bloodsport's "Theatrical Trailer" is a real title jump one level below
    /// the play button. A button the lexicon knows is *not* the feature must
    /// never win, however well-formed its command is.
    @Test func aTrailerIsNeverThePlayButton() throws {
        var structure = try Self.load("synthetic-movie")
        // Give the root menu a second title-jumping button: the trailer.
        var root = try #require(structure.menus.first { $0.id == "vtsm-01-lu1-pgc1" })
        root.buttons.append(
            MenuStructure.Button(
                number: 5,
                rect: PixelRect(minX: 388, minY: 308, maxX: 550, maxY: 338),
                autoAction: false,
                command: "3002000000030000",   // JumpTT 3
                up: nil, down: nil, left: nil, right: nil
            )
        )
        structure.menus = structure.menus.map { $0.id == root.id ? root : $0 }

        let labels = [
            MenuButtonRef(menu: "vtsm-01-lu1-pgc1", number: 1): "Play Movie",
            MenuButtonRef(menu: "vtsm-01-lu1-pgc1", number: 5): "Theatrical Trailer",
        ]
        let resolution = try #require(PlayButtonResolver.resolve(structure, labels: labels))
        #expect(resolution.title == 1)
        #expect(resolution.label == "Play Movie")
    }

    /// Two genuinely different feature candidates with no lexicon hit is the
    /// case tier 3 exists for. Until it lands, the honest answer is no line
    /// at all — never a guess.
    @Test func twoUnlabelledFeatureCandidatesResolveToNothing() throws {
        var structure = try Self.load("synthetic-movie")
        var root = try #require(structure.menus.first { $0.id == "vtsm-01-lu1-pgc1" })
        root.buttons.append(
            MenuStructure.Button(
                number: 5,
                rect: PixelRect(minX: 388, minY: 308, maxX: 550, maxY: 338),
                autoAction: false,
                command: "3002000000030000",
                up: nil, down: nil, left: nil, right: nil
            )
        )
        structure.menus = structure.menus.map { $0.id == root.id ? root : $0 }
        // Drop the VMGM title menu so only the two root candidates remain.
        structure.menus.removeAll { $0.id == "vmgm-lu1-pgc1" }
        #expect(PlayButtonResolver.resolve(structure) == nil)
    }

    // MARK: - The TV signal

    @Test func aMovieDiscHasNoTVSignal() throws {
        let structure = try Self.load("synthetic-movie")
        let signal = MenuTVSignal.evaluate(structure)
        #expect(signal.value == false)
        #expect(signal.reason.contains("≥3"))
    }

    @Test func threeTitleJumpsOnOneMenuRaiseTheTVSignal() throws {
        var structure = try Self.load("synthetic-movie")
        var root = try #require(structure.menus.first { $0.id == "vtsm-01-lu1-pgc1" })
        root.buttons = (1...3).map { index in
            MenuStructure.Button(
                number: index,
                rect: PixelRect(minX: 100, minY: 100 + index * 40, maxX: 300, maxY: 130 + index * 40),
                autoAction: false,
                command: String(format: "300200000%03x0000", index),
                up: nil, down: nil, left: nil, right: nil
            )
        }
        structure.menus = structure.menus.map { $0.id == root.id ? root : $0 }
        #expect(MenuTVSignal.evaluate(structure).value)
    }

    // MARK: - Attaching text to buttons

    @Test func aLabelIsTheObservationInsideTheButton() throws {
        let structure = try Self.load("synthetic-movie")
        let buttons = structure.resolvedButtons().filter { $0.ref.menu == "vtsm-01-lu1-pgc1" }
        let observations = [
            TextObservation(text: "Play Movie", confidence: 1, rect: PixelRect(minX: 400, minY: 152, maxX: 530, maxY: 174)),
            TextObservation(text: "Scene Selections", confidence: 1, rect: PixelRect(minX: 400, minY: 192, maxX: 540, maxY: 214)),
            // Decoration: a copyright line inside no button at all.
            TextObservation(text: "© 2002 Warner Home Video", confidence: 1, rect: PixelRect(minX: 40, minY: 440, maxX: 320, maxY: 460)),
        ]
        let labels = PlayButtonResolver.labels(buttons: buttons, observations: observations)
        #expect(labels[MenuButtonRef(menu: "vtsm-01-lu1-pgc1", number: 1)] == "Play Movie")
        #expect(labels[MenuButtonRef(menu: "vtsm-01-lu1-pgc1", number: 2)] == "Scene Selections")
        #expect(!labels.values.contains("© 2002 Warner Home Video"), "text inside no button is decoration, never a label")
    }
}
