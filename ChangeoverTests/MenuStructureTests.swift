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

    // MARK: - The reader's own self-checks

    /// The helper publishes how it found each NAV pack and how it checked
    /// itself, because the bug that made this necessary produced an empty
    /// `buttons` array with no stated cause — indistinguishable from a disc
    /// that genuinely has no buttons.
    @Test func everyMenuWithButtonsCarriesItsNavDiagnostics() throws {
        let structure = try Self.load("synthetic-movie")
        let withButtons = structure.menus.filter { !$0.buttons.isEmpty }
        #expect(withButtons.count == 4)
        for menu in withButtons {
            let nav = try #require(menu.nav, "\(menu.id): no nav block")
            #expect(nav.error == nil, "\(menu.id): \(nav.error ?? "")")
            #expect(nav.rectsInsideFrame == true, "\(menu.id)")
            #expect(nav.groupsAgree == true, "\(menu.id)")
            #expect((nav.pciOffset ?? -1) >= 0, "\(menu.id): no PCI packet located")
        }
    }

    /// The one check that does not share the parser's assumptions: the pack
    /// carries its own sector address, and it is compared with the sector
    /// the IFO's cell table sent the reader to. A four-byte slip in the PCI
    /// structure — the bug that read zero buttons off a real disc — makes
    /// this number stop being the sector number.
    @Test func theNavPackSelfReportsTheSectorItWasReadFrom() throws {
        let structure = try Self.load("synthetic-movie")
        for menu in structure.menus where !menu.buttons.isEmpty {
            let nav = try #require(menu.nav)
            #expect(nav.lbnMatches == true, "\(menu.id): nv_pck_lbn \(nav.lbn as Any) != sector \(nav.sector as Any)")
            #expect(nav.lbn == nav.sector, "\(menu.id)")
        }
    }

    /// A menu PGC no NAV pack could be read from says why in words, rather
    /// than reporting an empty button list and leaving the reader to guess
    /// whether the disc or the tool is at fault.
    @Test func aMenuWithNoReadableNavPackNamesItsReason() throws {
        let structure = try Self.load("synthetic-movie")
        let orphan = try #require(structure.menus.first { $0.id == "vtsm-01-lu1-pgc4" })
        #expect(orphan.buttons.isEmpty)
        let nav = try #require(orphan.nav)
        #expect(nav.error?.isEmpty == false, "an empty result with no cause is the failure this block exists to prevent")
        #expect(nav.pciOffset == -1)
    }

    /// `btngr_ns` is the number of button *groups* and `btn_ns` the count
    /// **per group**, so a reader that treats `btn_ns` as the total reads
    /// half a table and one that ignores groups reads past the end. The
    /// groups are the same buttons at different rectangles for different
    /// display aspects, so their commands must agree — which is what makes
    /// taking group 1 safe for tier 1.
    @Test func twoButtonGroupsAreCountedAndTheirCommandsAgree() throws {
        let structure = try Self.load("synthetic-movie")
        let root = try #require(structure.menus.first { $0.id == "vtsm-01-lu1-pgc1" })
        #expect(root.buttonGroups == 2)
        #expect(root.buttons.count == 4, "group 1 only — not 8, and not 2")
        let nav = try #require(root.nav)
        #expect(nav.buttonsPerGroup == 4)
        #expect(nav.groupsAgree == true)
        #expect(nav.groupDisplayTypes?.prefix(2) == [1, 2], "4:3 then widescreen")
        // Group 1's rectangles are the ones in `buttons`, and they are the
        // 4:3 layout — the widescreen group's are 40px wider either side.
        #expect(root.buttons.first?.rect == PixelRect(minX: 388, minY: 148, maxX: 550, maxY: 178))
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

    /// The shape the first real disc actually uses. Bloodsport's Play Movie
    /// button is a `LinkTailPGC` — "run this PGC's post-commands" — and the
    /// root PGC's post-commands end with `JumpVTS_TT 1`. A resolver that
    /// only understands a bare `JumpTT` on the button reads nothing at all,
    /// which is what it did.
    @Test func aPlayButtonThatRunsItsPGCsPostCommandsResolves() throws {
        var structure = try Self.load("synthetic-movie")
        var root = try #require(structure.menus.first { $0.id == "vtsm-01-lu1-pgc1" })
        // LinkTailPGC (button 1) in place of the direct jump…
        root.buttons[0].command = "200100000000040d"
        // …and the title jump moved into the PGC's own post-commands.
        root.commands = MenuStructure.Commands(pre: [], post: ["3003000000010000"], cell: [])
        structure.menus = structure.menus.map { $0.id == root.id ? root : $0 }
        structure.menus.removeAll { $0.id == "vmgm-lu1-pgc1" }

        #expect(structure.soleTitleJump(of: root) == 1, "JumpVTS_TT 1 lifts to VMG title 1 through TT_SRPT")
        let resolution = try #require(PlayButtonResolver.resolve(structure))
        #expect(resolution.title == 1)
        #expect(resolution.resolvedBy == .pgcCommands)
    }

    /// One step, never a chain, and never a conditional: a PGC whose
    /// commands jump to two different titles resolves to neither.
    @Test func aPGCThatJumpsToTwoTitlesResolvesToNeither() throws {
        var structure = try Self.load("synthetic-movie")
        var root = try #require(structure.menus.first { $0.id == "vtsm-01-lu1-pgc1" })
        root.buttons[0].command = "200100000000040d"
        root.commands = MenuStructure.Commands(
            pre: [], post: ["3003000000010000", "3002000000030000"], cell: []
        )
        structure.menus = structure.menus.map { $0.id == root.id ? root : $0 }
        #expect(structure.soleTitleJump(of: root) == nil)
    }

    /// "Scene Selections" and "Special Features" on the measured disc are
    /// set-then-link commands: they set a register *and* carry a trailing
    /// `LinkPGCN` in the same eight bytes. Treating the whole family as
    /// opaque left three of the four root-menu buttons unreadable.
    @Test func aSetThenLinkCommandStillNamesItsDestination() {
        let command = try? #require(VMCommand(hex: "560400002c000006"))
        #expect(command?.target(inVTS: 1) == .menu(MenuTargetRef(domain: nil, vts: 1, pgc: 6, menuID: nil)))
        #expect(VMCommand(hex: "5604000004000005")?.target(inVTS: 1)
                == .menu(MenuTargetRef(domain: nil, vts: 1, pgc: 5, menuID: nil)))
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

    // MARK: - A scene index spread over several pages

    /// The shape `Tools/menudump` writes for a multi-page menu, copied from
    /// what it produced reading a real disc (Oppenheimer's `pgc19`, five
    /// cells of four scenes). Pinning the literal JSON is the point: this is
    /// the contract between the C helper and this decoder, and a test built
    /// from a Swift value would agree with itself while the two drifted.
    static func pagedMenuJSON(pageCount: Int, buttonsPerPage: Int) -> String {
        func button(_ number: Int, chapter: Int) -> String {
            let top = 60 + (number - 1) * 100
            return """
            { "number": \(number), "rect": [512, \(top), 658, \(top + 90)], "autoAction": false, \
            "command": "3005\(String(format: "%04x", chapter))00010000", "up": 1, "down": 2, "left": 3, "right": 4 }
            """
        }
        let pages = (1...pageCount).map { page -> String in
            let still = page == 1 ? "vtsm-03-lu1-pgc19" : "vtsm-03-lu1-pgc19-cell\(page)"
            let buttons = (1...buttonsPerPage).map { index in
                button(index, chapter: (page - 1) * buttonsPerPage + index)
            }
            return """
            { "cell": \(page), "still": "\(still)", "rendered": true, \
            "nav": { "sector": \(page * 40), "lbnMatches": true, "buttonsPerGroup": \(buttonsPerPage), \
            "groupsAgree": true, "rectsInsideFrame": true, "error": null }, \
            "buttons": [\(buttons.joined(separator: ", "))] }
            """
        }
        let firstPageButtons = (1...buttonsPerPage).map { button($0, chapter: $0) }
        return """
        { "format": "changeover-menu-structure/1",
          "titles": [{ "title": 7, "vts": 3, "vtsTTN": 1, "ptts": 20, "angles": 1 }],
          "menus": [
            { "id": "vtsm-03-lu1-pgc19", "domain": "VTSM", "vts": 3, "languageUnit": 1, "pgc": 19,
              "entryType": "none",
              "buttons": [\(firstPageButtons.joined(separator: ", "))],
              "pages": [\(pages.joined(separator: ", "))],
              "stills": ["vtsm-03-lu1-pgc19", "vtsm-03-lu1-pgc19-cell2"] }
          ] }
        """
    }

    /// The defect this exists to prevent: reading cell 0 and calling it the
    /// menu. A five-page index addresses twenty chapters, and a reader that
    /// sees four of them hands `ChapterNames.markers` a set naming fewer than
    /// half the film's chapters — which it correctly throws away, so the disc
    /// silently yields no names at all.
    @Test func everyPageOfASceneIndexIsRead() throws {
        let structure = try MenuStructure.decode(
            Data(Self.pagedMenuJSON(pageCount: 5, buttonsPerPage: 4).utf8)
        )
        let menu = try #require(structure.menus.first)
        #expect(menu.pages?.count == 5)
        #expect(menu.buttons.count == 4, "the legacy field stays cell 0, so an old reader sees what it always saw")

        let buttons = structure.resolvedButtons()
        #expect(buttons.count == 20)

        let chapters = buttons.compactMap { button -> Int? in
            if case .chapter(_, let ptt) = button.target { return ptt }
            return nil
        }
        #expect(chapters.sorted() == Array(1...20))
    }

    /// A caption has to be paired against its own page's geometry: every page
    /// puts its buttons at the same coordinates, so pooling them first would
    /// let page 3's text claim page 1's button.
    @Test func aButtonIsAddressedByThePageItIsPrintedOn() throws {
        let structure = try MenuStructure.decode(
            Data(Self.pagedMenuJSON(pageCount: 5, buttonsPerPage: 4).utf8)
        )
        let byPage = Dictionary(grouping: structure.resolvedButtons(), by: { $0.ref.menu })
        #expect(byPage.count == 5)
        #expect(byPage["vtsm-03-lu1-pgc19"]?.count == 4, "cell 0's page keeps the menu's own id")
        #expect(byPage["vtsm-03-lu1-pgc19-cell5"]?.count == 4)

        // Page 5 addresses chapters 17-20 and nothing else.
        let lastPage = try #require(byPage["vtsm-03-lu1-pgc19-cell5"])
        let chapters = lastPage.compactMap { button -> Int? in
            if case .chapter(_, let ptt) = button.target { return ptt }
            return nil
        }
        #expect(chapters.sorted() == [17, 18, 19, 20])

        #expect(structure.chapterPageIDs().count == 5, "each page is a scene page in its own right")
    }

    /// A capture made before the helper read past the first cell has no
    /// `pages` at all. It must keep reading exactly as it did — a missing
    /// array is an older document, not a menu without buttons.
    @Test func aCaptureWithNoPagesStillReadsItsButtons() throws {
        let structure = try Self.load("synthetic-movie")
        #expect(structure.menus.allSatisfy { $0.pages == nil })

        let chapterMenu = try #require(structure.menus.first { $0.id == "vtsm-01-lu1-pgc2" })
        #expect(chapterMenu.buttonPages.count == 1)
        #expect(chapterMenu.buttonPages.first?.still == chapterMenu.id,
                "one page, named after the menu — which is what cell 0's page is called either way")

        let refs = Set(structure.resolvedButtons().map(\.ref.menu))
        #expect(refs.contains("vtsm-01-lu1-pgc2"))
        #expect(structure.chapterPageIDs().contains("vtsm-01-lu1-pgc2"))
    }
}
