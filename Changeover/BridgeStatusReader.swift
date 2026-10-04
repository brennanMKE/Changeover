import ChangeoverBridge
import Foundation

/// #0189 — turns the app's live state into the snapshot `changeoverctl status`
/// prints and every `watch` event draws its detail from.
///
/// Split into two halves on purpose.
///
/// The **projection** half is a set of `nonisolated static` functions that take
/// the app's own plain values — a `DiscInsertion`, a `ScanState`, a
/// `StartDecision` — and return the wire types. Every one is pure, so the
/// mapping that actually has judgement in it (which `FlowStep` payload becomes
/// which string, what `percent` means when HandBrake is muxing, when `film` is
/// `nil` rather than empty) is testable in `ChangeoverTests` with no app, no
/// disc and no XPC connection. That is the only coverage available: UI tests are
/// forbidden in this project, and the transport is verified by hand.
///
/// The **reading** half is `snapshot(…)`, which is `@MainActor` because
/// `JobController` and `RipFlowController` are, and does nothing but pull
/// properties off them and hand them to the projection. It is deliberately dull.
/// It must also be *read-only*: `status` and `watch` observe, and nothing here
/// may start, cancel, eject or import. Every call below is a property read or a
/// pure derivation the app already performs for its own window.
///
/// `snapshot(…)` is also what the event feed's observation tracking is armed
/// around, so touching a property here is what makes a change to it produce an
/// event. A field added to the snapshot becomes watchable for free; a field read
/// somewhere else does not.
nonisolated enum BridgeStatusReader {

    // MARK: - Reading

    @MainActor
    static func snapshot(
        jobs: JobController,
        flow: RipFlowController,
        settings: AppSettings,
        launchDate: Date,
        clients: Int,
        sessions: Int,
        brokerRegistered: Bool
    ) -> BridgeStatus {
        let step = flow.step(jobs: jobs)
        let scanState = jobs.scanState
        let phase = DiscPhaseIndicator.phase(
            step: step,
            scanned: Self.hasScanned(scanState),
            plan: flow.ripPlan
        )

        return BridgeStatus(
            app: appStatus(
                settings: settings,
                launchDate: launchDate,
                clients: clients,
                sessions: sessions,
                brokerRegistered: brokerRegistered
            ),
            disc: discStatus(
                jobs.insertedDisc,
                isEjecting: jobs.isEjecting,
                unavailable: jobs.discUnavailable,
                hasMoreWork: jobs.discHasMoreWork
            ),
            flow: flowStatus(step: step, phase: phase),
            scan: scanStatus(scanState, menuState: jobs.menuState),
            film: filmStatus(
                flow.chosenMovie.map { MovieMetadata(from: $0, edition: flow.edition) },
                resolvedBy: flow.resolvedBy,
                chosenByUser: IdentificationSummary.wasChosenByUser(jobs.identificationNarration),
                libraryCheck: flow.libraryCheckForThisEdition
            ),
            job: jobStatus(jobs),
            start: startStatus(
                flow.startDecision(jobs: jobs),
                autoStartSecondsRemaining: flow.autoStartRemaining
            ),
            automation: automationStatus(attachedSessions: sessions),
            library: libraryStatus(settings: settings)
        )
    }

    // MARK: - Projection

    @MainActor
    static func appStatus(
        settings: AppSettings,
        launchDate: Date,
        clients: Int,
        sessions: Int,
        brokerRegistered: Bool
    ) -> AppStatus {
        AppStatus(
            pid: ProcessInfo.processInfo.processIdentifier,
            version: Bundle.main.bridgeShortVersion,
            build: Bundle.main.bridgeBuildVersion,
            uptimeSeconds: Date().timeIntervalSince(launchDate),
            isConfigured: settings.isConfigured,
            clients: clients,
            sessions: sessions,
            brokerRegistered: brokerRegistered
        )
    }

    static func discStatus(
        _ disc: DiscInsertion?,
        isEjecting: Bool,
        unavailable: Bool,
        hasMoreWork: Bool
    ) -> DiscStatus? {
        guard let disc else { return nil }
        return DiscStatus(
            label: disc.label,
            discID: disc.discID,
            // The insertion token, not the disc id. It is what distinguishes two
            // visits by discs that share a path, a device node and an unknown
            // identity — the case `SelectionReset.sameDisc` exists for.
            insertionID: disc.insertionID.uuidString,
            mountPath: disc.mountURL.path,
            deviceNode: disc.deviceNode,
            isMounted: disc.isMounted,
            isEjecting: isEjecting,
            unavailable: unavailable,
            hasMoreWork: hasMoreWork
        )
    }

    static func flowStatus(step: FlowStep, phase: DiscPhase) -> FlowStatus {
        FlowStatus(
            step: name(of: step),
            stepDetail: detail(of: step),
            discPhase: phase.rawValue,
            discPhaseNumber: phase.number,
            discPhaseCount: DiscPhase.count,
            discPhaseTitle: phase.title
        )
    }

    /// The case name alone, without its payload.
    ///
    /// Hand-written rather than `String(describing:)`, which renders
    /// `insertDisc(Changeover.FlowStep.InsertReason.noDisc)` — a string carrying
    /// the module name and therefore liable to change for reasons that have
    /// nothing to do with the flow. The wire value has to be stable.
    static func name(of step: FlowStep) -> String {
        switch step {
        case .insertDisc: "insertDisc"
        case .ejected: "ejected"
        case .chooseMovie: "chooseMovie"
        case .confirm: "confirm"
        case .ripping: "ripping"
        case .done: "done"
        }
    }

    /// The payload, rendered for a reader. `nil` for the cases that carry none.
    static func detail(of step: FlowStep) -> String? {
        switch step {
        case .insertDisc(let reason): reason.rawValue
        case .ejected(let explanation): explanation.headline
        case .chooseMovie, .confirm: nil
        case .ripping(let id): id.rawValue
        case .done(let id): id.rawValue
        }
    }

    static func hasScanned(_ state: ScanState) -> Bool {
        if case .scanned = state { return true }
        return false
    }

    static func scanStatus(_ state: ScanState, menuState: MenuState) -> ScanStatus {
        switch state {
        case .idle:
            return ScanStatus(state: ScanStatus.State.idle, menuState: menuState.diagnosticName)
        case .scanning:
            return ScanStatus(state: ScanStatus.State.scanning, menuState: menuState.diagnosticName)
        case .scanned(let result):
            let feature = result.mainFeatureIndex.flatMap { index in
                result.disc.titles.first { $0.index == index }
            }
            return ScanStatus(
                state: ScanStatus.State.scanned,
                titleCount: result.disc.titles.count,
                mainFeatureIndex: result.mainFeatureIndex,
                featureDurationSeconds: feature?.durationSeconds,
                warnings: result.warnings,
                menuState: menuState.diagnosticName
            )
        case .failed(let failure):
            return ScanStatus(
                state: ScanStatus.State.failed,
                failure: describe(failure),
                menuState: menuState.diagnosticName
            )
        }
    }

    /// A `DiscScanner.Failure` as a sentence.
    ///
    /// Spelled out rather than `String(describing:)` because these are the
    /// strings a person reads when a disc will not scan, and `toolMissing(path:
    /// "/opt/homebrew/bin/HandBrakeCLI")` is a worse answer than naming the
    /// missing tool and what to do about it.
    static func describe(_ failure: DiscScanner.Failure) -> String {
        switch failure {
        case .toolMissing(let path):
            "HandBrakeCLI is not at \(path) — install it with `brew install handbrake`, "
                + "or correct the path in Settings"
        case .launchFailure(let message):
            "HandBrakeCLI could not be launched: \(message)"
        case .toolExited(let code):
            "HandBrakeCLI exited with code \(code)"
        case .jsonMissing:
            "HandBrakeCLI produced no title JSON"
        case .titleSetCorrupted:
            "the disc's title set is unreadable"
        case .cancelled:
            "the scan was cancelled"
        }
    }

    static func filmStatus(
        _ metadata: MovieMetadata?,
        resolvedBy: String?,
        chosenByUser: Bool,
        libraryCheck: LibraryCheck
    ) -> FilmStatus? {
        guard let metadata else { return nil }
        return FilmStatus(
            title: metadata.title,
            year: metadata.year,
            tmdbID: metadata.tmdbID,
            edition: metadata.edition,
            // Taken from `MovieMetadata` rather than rebuilt, so the names the
            // CLI reports are the names `PlexOrganizer` will actually write.
            folderName: metadata.folderName,
            fileName: metadata.fileName,
            resolvedBy: chosenByUser ? "user" : resolvedBy,
            chosenByUser: chosenByUser,
            libraryStatus: describe(libraryCheck)
        )
    }

    static func describe(_ check: LibraryCheck) -> String {
        switch check {
        case .idle: "idle"
        case .checking: "checking"
        case .done(_, .absent): "absent"
        case .done(_, .present): "present"
        case .done(_, .unreachable): "unreachable"
        }
    }

    @MainActor
    static func jobStatus(_ jobs: JobController) -> JobStatus? {
        // `current ?? history.last` is the app's own definition of "the job
        // being talked about" (`JobController.currentJobID`), so the CLI reports
        // the same job the window does rather than inventing a second rule.
        guard let state = jobs.currentJobState else { return nil }
        let job = jobs.current
        let progress = job?.progress
        let outcome = jobs.lastOutcome ?? job?.outcome

        return JobStatus(
            running: jobs.isRunning,
            id: jobs.currentJobID,
            phase: state.phase.rawValue,
            percent: percent(of: progress),
            unit: progress.map { unitName(of: $0.unit) },
            extraIndex: extraIndex(of: progress?.unit),
            extraCount: extraCount(of: progress?.unit),
            etaSeconds: progress?.encode.etaSeconds,
            averageFPS: progress?.encode.averageFPS,
            outcome: outcomeName(outcome),
            failureReason: failureReason(outcome),
            film: filmStatus(
                jobs.currentMetadata,
                resolvedBy: nil,
                chosenByUser: false,
                libraryCheck: .idle
            )
        )
    }

    /// 0…100, or `nil` when the step genuinely has no percentage.
    ///
    /// `nil` is a real answer rather than a gap, and the two cases that produce
    /// it are both deliberate. A metadata-upgrade remux is an `ffmpeg -c copy`
    /// pass whose `-progress` output is not parsed, and muxing is the tail of an
    /// encode with no percentage of its own. A consumer must render "working",
    /// not "0 %" — which is why this returns `nil` instead of a zero that looks
    /// like a stalled encode.
    static func percent(of progress: JobProgress?) -> Double? {
        guard let progress else { return nil }
        if case .remux = progress.unit { return nil }
        if progress.encode.stage == .muxing { return nil }
        return progress.encode.fraction * 100
    }

    static func unitName(of unit: JobProgress.Unit) -> String {
        switch unit {
        case .feature: "feature"
        case .fallback: "fallback"
        case .extra: "extra"
        case .remux: "remux"
        }
    }

    static func extraIndex(of unit: JobProgress.Unit?) -> Int? {
        guard case .extra(let index, _, _) = unit else { return nil }
        return index
    }

    static func extraCount(of unit: JobProgress.Unit?) -> Int? {
        guard case .extra(_, let count, _) = unit else { return nil }
        return count
    }

    static func outcomeName(_ outcome: JobOutcome?) -> String? {
        guard let outcome else { return nil }
        return JobState.terminalPhase(for: outcome).rawValue
    }

    /// The failure as the app itself words it.
    ///
    /// Through `FailurePresenter.headline`, not `String(describing: reason)`.
    /// The presenter is where "HandBrakeCLI is not installed at …" and "the
    /// destination volume is full" are written, and it already knows that the
    /// same `FailureReason` means different things at different stages. A second
    /// rendering here would be a second thing to keep in step, and the CLI's
    /// answer would stop matching the one on screen.
    static func failureReason(_ outcome: JobOutcome?) -> String? {
        guard let failure = outcome?.failure else { return nil }
        return FailurePresenter.headline(for: failure.reason, stage: failure.stage)
    }

    static func startStatus(
        _ decision: StartDecision,
        autoStartSecondsRemaining: Int?
    ) -> StartStatus {
        StartStatus(
            // `permitsStart`, never `== .ready`. There are two permitting cases
            // and they start different jobs; comparing against one of them is
            // the bug that flag exists to prevent.
            permitted: decision.permitsStart,
            decision: decision.rawValue,
            reason: decision.reason,
            plainReason: decision.plainReason,
            autoStartSecondsRemaining: autoStartSecondsRemaining
        )
    }

    static func automationStatus(attachedSessions: Int) -> AutomationStatus {
        AutomationStatus(
            suspended: AutomationSuspension.isSuspended(attachedSessions: attachedSessions),
            heldBySessions: max(0, attachedSessions),
            reason: AutomationSuspension.reason(attachedSessions: attachedSessions)
        )
    }

    @MainActor
    static func libraryStatus(settings: AppSettings) -> LibraryStatus {
        let roots = settings.libraryRoots
        return LibraryStatus(
            mediaRoot: settings.plexMediaRoot,
            moviesPath: roots.moviesPath,
            tvShowsPath: roots.tvPath,
            // Taken from `PlexExtra.Kind` rather than written out here, so a kind
            // added to the app appears in the CLI's answer without anyone
            // remembering to. The order is the declaration order, which is also
            // the order the app's own UI lists them in.
            extrasFolders: PlexExtra.Kind.allCases.map(\.folderName)
        )
    }
}

extension Bundle {
    /// `CFBundleShortVersionString`, or a marker rather than a guess.
    ///
    /// Nothing in the Swift source holds the version: it lives only in
    /// `Config/App.xcconfig`, because a second copy is how a DMG ends up named
    /// for one version while the bundle inside it reports another. So it is read
    /// from the bundle here, and an absent key is reported as unknown rather
    /// than defaulted to something plausible — a CLI that reports a version the
    /// app does not have is worse than one that reports none.
    var bridgeShortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    var bridgeBuildVersion: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}
