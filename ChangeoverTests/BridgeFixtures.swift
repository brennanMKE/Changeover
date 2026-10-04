import ChangeoverBridge
import Foundation

/// Snapshot builders for the #0189 bridge tests.
///
/// `BridgeStatus` has nine fields and most tests care about one. Building them
/// here, with every parameter defaulted, is what lets each test name only what it
/// is about — the same reason `FlowStep.Inputs` and `DiscPhase.Inputs` default
/// every field.
enum BridgeFixtures {

    static func app(clients: Int = 1, sessions: Int = 0) -> AppStatus {
        AppStatus(
            pid: 4242,
            version: "0.1.3-pre1",
            build: "1",
            uptimeSeconds: 12,
            isConfigured: true,
            clients: clients,
            sessions: sessions,
            brokerRegistered: true
        )
    }

    static func disc(
        label: String = "GARDEN_STATE",
        discID: String? = "abc123",
        insertionID: String = "11111111-1111-1111-1111-111111111111",
        isEjecting: Bool = false,
        unavailable: Bool = false,
        hasMoreWork: Bool = false
    ) -> DiscStatus {
        DiscStatus(
            label: label,
            discID: discID,
            insertionID: insertionID,
            mountPath: "/Volumes/\(label)",
            deviceNode: "disk6",
            isEjecting: isEjecting,
            unavailable: unavailable,
            hasMoreWork: hasMoreWork
        )
    }

    static func flow(
        step: String = "chooseMovie",
        stepDetail: String? = nil,
        phase: String = "selecting",
        number: Int = 2
    ) -> FlowStatus {
        FlowStatus(
            step: step,
            stepDetail: stepDetail,
            discPhase: phase,
            discPhaseNumber: number,
            discPhaseCount: 5,
            discPhaseTitle: "Choosing"
        )
    }

    static func scan(
        state: String = ScanStatus.State.idle,
        titleCount: Int? = nil,
        mainFeatureIndex: Int? = nil,
        failure: String? = nil
    ) -> ScanStatus {
        ScanStatus(
            state: state,
            titleCount: titleCount,
            mainFeatureIndex: mainFeatureIndex,
            failure: failure
        )
    }

    static func film(
        title: String = "Garden State",
        year: String = "2004",
        tmdbID: String = "401",
        edition: String? = nil,
        resolvedBy: String? = "label",
        chosenBy: String = FilmStatus.Chooser.automation,
        libraryStatus: String = "absent"
    ) -> FilmStatus {
        FilmStatus(
            title: title,
            year: year,
            tmdbID: tmdbID,
            edition: edition,
            folderName: "\(title) (\(year)) {tmdb-\(tmdbID)}",
            fileName: "\(title) (\(year)).mp4",
            resolvedBy: resolvedBy,
            chosenBy: chosenBy,
            libraryStatus: libraryStatus
        )
    }

    static func job(
        running: Bool = true,
        id: String = "job-1",
        phase: String = "encoding",
        percent: Double? = 10,
        unit: String? = "feature",
        extraIndex: Int? = nil,
        extraCount: Int? = nil,
        outcome: String? = nil,
        failureReason: String? = nil,
        cancelledBy: String? = nil,
        film: FilmStatus? = nil
    ) -> JobStatus {
        JobStatus(
            running: running,
            id: id,
            phase: phase,
            percent: percent,
            unit: unit,
            extraIndex: extraIndex,
            extraCount: extraCount,
            outcome: outcome,
            failureReason: failureReason,
            cancelledBy: cancelledBy,
            film: film
        )
    }

    static func start(
        permitted: Bool = false,
        decision: String = "scanInProgress",
        reason: String? = "The disc is still being read."
    ) -> StartStatus {
        StartStatus(permitted: permitted, decision: decision, reason: reason)
    }

    static func library() -> LibraryStatus {
        LibraryStatus(
            mediaRoot: "/Volumes/Media/Media",
            moviesPath: "/Volumes/Media/Media/Movies",
            tvShowsPath: "/Volumes/Media/Media/TV Shows",
            extrasFolders: ["Behind The Scenes", "Other"]
        )
    }

    static func status(
        app: AppStatus? = nil,
        disc: DiscStatus? = nil,
        flow: FlowStatus? = nil,
        scan: ScanStatus? = nil,
        film: FilmStatus? = nil,
        job: JobStatus? = nil,
        start: StartStatus? = nil,
        sessions: Int = 0
    ) -> BridgeStatus {
        BridgeStatus(
            app: app ?? Self.app(sessions: sessions),
            disc: disc,
            flow: flow ?? Self.flow(),
            scan: scan ?? Self.scan(),
            film: film,
            job: job,
            start: start ?? Self.start(),
            automation: AutomationStatus(
                suspended: sessions > 0,
                heldBySessions: sessions,
                reason: sessions > 0 ? "held" : nil
            ),
            library: Self.library()
        )
    }
}
