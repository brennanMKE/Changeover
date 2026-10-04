import ChangeoverBridge
import Foundation

/// #0197 — the app's side of `changeoverctl assets`, `library` and `search`.
///
/// **Every verb here only reads.** Nothing in this file starts, cancels, ejects
/// or imports, and that is structural rather than careful: the only app state any
/// of these functions touches is a property read, and the only things they write
/// are files in a temporary directory nothing else looks at. The acting verbs live
/// elsewhere, so "can this command change anything?" is answered by which file it
/// is in.
///
/// It is also deliberately dull, in the register `BridgeStatusReader`'s reading
/// half is dull. The judgement is in the pure projections — `BridgeAssetCache`,
/// `BridgeLibraryReader` — which take plain values and are testable with no app,
/// no disc and no XPC connection. What is left here is pulling properties off
/// `JobController` and `AppSettings` and handing them over, which is exactly how
/// much of this should be untestable.
///
/// `async` because two of the three genuinely wait: the cache copies files and the
/// library probe lists a volume that may be an SMB mount, and a search is three
/// network round trips. None of that waiting happens on the main actor —
/// `BridgeAssetCache.write` and `LibraryProbe.lookup` are both `@concurrent`, for
/// the same reason `PlexOrganizer.move` is.
@MainActor
enum BridgeReadVerbs {

    /// The actions this type answers. Read by `AppXPCServer.handle` so the switch
    /// there stays one case wide.
    static let actions: Set<String> = [
        BridgeRequest.Action.assets,
        BridgeRequest.Action.library,
        BridgeRequest.Action.search,
    ]

    static func handle(
        _ request: BridgeRequest,
        jobs: JobController,
        settings: AppSettings
    ) async -> BridgeResponse {
        switch request.action {
        case BridgeRequest.Action.assets:
            return await assets(jobs: jobs, settings: settings)
        case BridgeRequest.Action.library:
            return await library(request, jobs: jobs, settings: settings)
        case BridgeRequest.Action.search:
            return await search(request, settings: settings)
        default:
            // Unreachable while `actions` and this switch agree, and a refusal
            // rather than a trap if they ever stop agreeing: a dispatch mistake
            // must not take the app down in front of the user.
            return .failure("'\(request.action)' is not one of the read verbs")
        }
    }

    // MARK: - assets

    /// Collects everything known about the disc in the drive.
    ///
    /// Refuses with no disc mounted, and says so in those words. An empty manifest
    /// would be worse than a refusal: it reads as "this disc has nothing on it",
    /// which is a finding, and there is no disc to have found it about.
    private static func assets(jobs: JobController, settings: AppSettings) async -> BridgeResponse {
        guard let insertion = jobs.insertedDisc else {
            return .failure(
                "there is no disc in the drive, so there is nothing collected to report"
            )
        }

        let scanState = jobs.scanState
        let menuState = jobs.menuState
        let scanned: DiscScanner.Result? = {
            if case .scanned(let result) = scanState { return result }
            return nil
        }()
        let ocr = menuState.intelligence?.ocr

        // The menu lines through `DiscEvidence.make`, which is the one place in
        // the app that turns OCR observations into menu lines — the filtering it
        // does (empty text out, furniture repeated across pages out, repeats
        // *within* a page kept) is itself a judgement, and a second copy of it in
        // the CLI's answer would eventually disagree with the one the app reasons
        // over. The disc passed in is the scan when there is one and an empty
        // stand-in when there is not, because menu text is readable before the
        // titles are known and withholding it until the scan lands would be
        // withholding it for no reason.
        let evidence = DiscEvidence.make(
            volumeName: insertion.label,
            ocr: ocr,
            disc: scanned?.disc
                ?? DiscInfo(volumeName: insertion.label, driveName: "", titles: []),
            mainFeatureIndex: scanned?.mainFeatureIndex
        )

        let slug = MenuArchive.slug(discID: insertion.discID, volumeName: insertion.label)
        let archiveRoot = settings.menuArchivePath
        let scan = BridgeAssetCache.scanSummary(scanState)
        let menus = BridgeAssetCache.menuSummary(menuState, menuPages: evidence.menuPages)

        let plan = BridgeAssetCache.Plan(
            directory: AssetCache.directory(slug: slug),
            archiveDirectory: archiveRoot.isEmpty
                ? nil
                : MenuArchive.discDirectory(root: archiveRoot, slug: slug),
            disc: BridgeAssetCache.disc(insertion),
            scan: scan,
            discInfo: scanned?.disc,
            mainFeatureIndex: scanned?.mainFeatureIndex,
            ocr: ocr,
            menuPages: evidence.menuPages,
            menus: menus,
            titles: scanned.map {
                BridgeAssetCache.titles(of: $0.disc, mainFeatureIndex: $0.mainFeatureIndex)
            } ?? [],
            notes: BridgeAssetCache.notes(
                scan: scan,
                menus: menus,
                archiveEnabled: !archiveRoot.isEmpty,
                hasOCR: ocr != nil
            )
        )

        let manifest = await BridgeAssetCache.write(plan)
        return .success("collected \(manifest.artifacts.count) artifact(s)", body: manifest)
    }

    // MARK: - library

    /// How long the CLI waits for the library listing.
    ///
    /// Longer than `LibraryProbe.defaultTimeout`'s five seconds, and the
    /// difference is deliberate. That five seconds exists so a dead SMB mount
    /// cannot hold the Confirm step — and a *person* — hostage; it is a UI
    /// responsiveness budget. Nothing is waiting on this call but a script that
    /// asked for an answer and passed its own `--timeout`, and the listing now
    /// measures each extra's runtime, so cutting it off at five seconds would
    /// report a reachable library as unreachable for no one's benefit.
    static let libraryTimeout: Duration = .seconds(15)

    private static func library(
        _ request: BridgeRequest,
        jobs: JobController,
        settings: AppSettings
    ) async -> BridgeResponse {
        guard let tmdbID = request.params[BridgeRequest.Param.tmdbID], !tmdbID.isEmpty else {
            return .failure("library needs a TMDB id")
        }

        let moviesPath = settings.plexMoviesPath

        // Answered here rather than let through to the probe, which would list a
        // path of `/Movies` and report it missing. "The library root is not
        // configured" and "the library root is not mounted" are different problems
        // with different fixes, and the second is not the user's answer to the
        // first.
        guard !settings.plexMediaRoot.isEmpty else {
            return .success(
                "the Plex library is not configured",
                body: LibraryReport(
                    tmdbID: tmdbID,
                    moviesPath: moviesPath,
                    tag: LibraryMatch.tag(for: tmdbID),
                    state: LibraryReport.State.unreachable,
                    reason: "the Plex media root has not been set — open Settings ▸ Library. "
                        + "This tool cannot set it: `changeoverctl` changes no settings."
                )
            )
        }

        let lookup = await LibraryProbe.lookup(
            moviesPath: moviesPath,
            tmdbID: tmdbID,
            timeout: libraryTimeout
        )

        let titles: [DiscTitle] = {
            if case .scanned(let result) = jobs.scanState { return result.disc.titles }
            return []
        }()

        let report = BridgeLibraryReader.report(
            tmdbID: tmdbID,
            moviesPath: moviesPath,
            lookup: lookup,
            discTitles: titles
        )
        // `ok: true` for all three states, `unreachable` included: the request
        // succeeded and "I could not read the library" is the answer. Reporting it
        // as a failure would make exit 4 mean both "the app refused" and "the NAS
        // is asleep", and the state is in the payload where a caller has to look
        // anyway to tell `filed` from `absent`.
        return .success(report.state, body: report)
    }

    // MARK: - search

    private static func search(
        _ request: BridgeRequest,
        settings: AppSettings
    ) async -> BridgeResponse {
        guard let term = request.params[BridgeRequest.Param.term]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !term.isEmpty
        else {
            return .failure("search needs something to search for")
        }
        let apiKey = settings.tmdbAPIKey
        guard !apiKey.isEmpty else {
            return .failure(
                "no TMDB API key is configured — set one in Settings ▸ General. "
                    + "`changeoverctl` cannot set it: this tool changes no settings."
            )
        }

        // A client of its own rather than the Choose step's.
        //
        // `MovieSearchViewModel` owns the one the window uses, and its `results`,
        // `selectedMovie` and runtime lookup are what the person is looking at. A
        // CLI search must not be able to touch any of that, and the cheapest way
        // to guarantee it is not to hold the object that could. The cost is a cold
        // details cache per call, which is one extra round trip on a question an
        // agent asks seconds apart at worst.
        let client = TMDBClient()
        do {
            let found = try await client.searchMovies(query: term, apiKey: apiKey)
            // The app's own ranking — exact title match, then prefix, newest
            // first within each group — so the order an agent sees is the order
            // the Choose step would show. A second ordering here would make the
            // CLI's "first result" mean something different from the window's.
            let ordered = MovieSearchViewModel.sorted(found, for: term)

            var hits: [SearchHit] = []
            var detailed = 0
            for (offset, movie) in ordered.enumerated() {
                // Runtime costs one request each and TMDB's rate limit is shared,
                // so only the first few are looked up. `try?`: a details lookup
                // that fails leaves that row without a runtime rather than failing
                // the whole search, because the title and the id are still the
                // answer to what was asked.
                var details: TMDBMovieDetails?
                if offset < SearchReport.detailBudget {
                    details = try? await client.movieDetails(id: movie.id, apiKey: apiKey)
                    if details != nil { detailed += 1 }
                }
                hits.append(
                    SearchHit(
                        tmdbID: String(movie.id),
                        title: movie.title,
                        year: movie.yearText,
                        releaseDate: movie.releaseDate,
                        runtimeMinutes: details?.runtimeMinutes,
                        director: details?.director,
                        cast: details?.leadCast ?? [],
                        // Built through `MovieMetadata`, never assembled here, so
                        // the name reported is the name `PlexOrganizer` would
                        // actually write — tag, path-sanitising and all.
                        folderName: MovieMetadata(from: movie).folderName,
                        posterURL: client.posterURL(path: movie.posterPath)?.absoluteString
                    )
                )
            }

            // An empty list is a success. "There is no such film" is a finding,
            // and a failure here would say the request never got through.
            return .success(
                "\(hits.count) result(s)",
                body: SearchReport(term: term, results: hits, detailedCount: detailed)
            )
        } catch {
            return .failure(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}
