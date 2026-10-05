// ReadCommands.swift

import ChangeoverBridge
import Foundation

// #0197 — `assets`, `library` and `search`: the three verbs that only read.
//
// In their own file, as an extension on ``Commands``, for two reasons. The merge
// reason is that Phase 2's acting verbs are being written at the same time and
// two agents editing one 300-line file is a conflict for nothing. The lasting
// reason is better: the verbs that cannot change anything are kept apart from the
// verbs that can, so "does this command only observe?" is answered by which file
// it is in rather than by reading it.
//
// All three go through one helper, because the shape is identical — connect,
// perform, decode, report — and three copies of it would be three places for the
// exit-code mapping to drift.

extension Commands {

    // MARK: - assets

    /// Asks the app to collect the disc's artifacts and prints where it put them.
    ///
    /// The app does the writing, not this process. It has to: the cache is built
    /// from the OCR document and the scan result, which live in the app's memory
    /// and have never been on disk anywhere this tool could read. Sending the
    /// manifest back rather than the artifacts themselves is what keeps the XPC
    /// message small while the stills stay out of it.
    static func assets(_ options: CLICommand.AssetsOptions, reporter: Reporter) async -> Int32 {
        await read(
            BridgeRequest(action: BridgeRequest.Action.assets),
            noLaunch: options.noLaunch,
            timeout: options.timeout,
            reporter: reporter,
            as: AssetManifest.self,
            missing: "the app replied without an assets manifest"
        ) { manifest, reporter in
            reporter.result(assets: manifest, humanLines: manifest.humanLines)
        }
    }

    // MARK: - library

    /// Asks whether one film is filed, and what its folder holds.
    ///
    /// Returns exit 0 for all three library states, `unreachable` included. The
    /// request succeeded — the app answered, and "I could not read the library"
    /// is the answer — so failing here would conflate a dead mount with a broken
    /// connection and leave `if ! changeoverctl library …` meaning two things.
    /// The state is in the output, which is where a caller has to look anyway to
    /// tell `filed` from `absent`.
    static func library(_ options: CLICommand.LibraryOptions, reporter: Reporter) async -> Int32 {
        await read(
            BridgeRequest(
                action: BridgeRequest.Action.library,
                params: [BridgeRequest.Param.tmdbID: options.tmdbID]
            ),
            noLaunch: options.noLaunch,
            timeout: options.timeout,
            reporter: reporter,
            as: LibraryReport.self,
            missing: "the app replied without a library report"
        ) { report, reporter in
            reporter.result(library: report, humanLines: report.humanLines)
        }
    }

    // MARK: - search

    /// Searches TMDB through the app.
    ///
    /// A search that matches nothing is a success with an empty list, not a
    /// failure: "there is no such film" is a finding, and exit 4 would say the
    /// request did not get through. A missing API key *is* exit 4, because then
    /// nothing was asked.
    static func search(_ options: CLICommand.SearchOptions, reporter: Reporter) async -> Int32 {
        await read(
            BridgeRequest(
                action: BridgeRequest.Action.search,
                params: {
                    var params = [BridgeRequest.Param.term: options.term]
                    // #0215 — only when given, so an unversioned search sends
                    // exactly what it always did.
                    if let year = options.year {
                        params[BridgeRequest.Param.year] = String(year)
                    }
                    return params
                }()
            ),
            noLaunch: options.noLaunch,
            timeout: options.timeout,
            reporter: reporter,
            as: SearchReport.self,
            missing: "the app replied without a search report"
        ) { report, reporter in
            reporter.result(search: report, humanLines: report.humanLines)
        }
    }

    // MARK: - The shared round trip

    /// Connect, perform one request, decode its body, report it.
    ///
    /// `report` is a closure rather than a return value so that the only path
    /// which prints is one that already holds a decoded body — a command cannot
    /// accidentally print a success line for a reply it failed to read.
    private static func read<Body: Decodable>(
        _ request: BridgeRequest,
        noLaunch: Bool,
        timeout seconds: Double,
        reporter: Reporter,
        as type: Body.Type,
        missing: String,
        report: (Body, Reporter) -> Void
    ) async -> Int32 {
        let timeout = CLIParse.duration(seconds)
        do {
            let app = try await AppConnection.connect(
                launchIfNeeded: !noLaunch,
                launchTimeout: timeout,
                note: reporter.note
            )
            defer { app.close() }

            let response = try await app.perform(request, timeout: timeout)

            // An `ok` reply whose payload will not decode is a version mismatch,
            // and it is named as one: a newer app sending a shape this build does
            // not understand is a different problem from the app refusing, and
            // "the request failed" would send someone looking in the wrong place.
            guard response.ok else {
                return reporter.failure(
                    CLIErrorPayload(
                        code: BridgeExitCode.requestFailed,
                        kind: CLIErrorPayload.Kind.requestFailed,
                        message: response.message
                    )
                )
            }
            guard let body = response.body(as: type) else {
                return reporter.failure(
                    CLIErrorPayload(
                        code: BridgeExitCode.requestFailed,
                        kind: CLIErrorPayload.Kind.undecodable,
                        message: missing,
                        hint: "this copy of the tool and the app may be out of sync — "
                            + "compare `\(ServiceNames.cliName) --version` with the app's version"
                    )
                )
            }

            report(body, reporter)
            return BridgeExitCode.success
        } catch let error as TransportError {
            return reporter.failure(error.payload)
        } catch {
            return reporter.failure(
                CLIErrorPayload(
                    code: BridgeExitCode.requestFailed,
                    kind: CLIErrorPayload.Kind.requestFailed,
                    message: error.localizedDescription
                )
            )
        }
    }
}

// MARK: - Reporting

/// The read verbs' output.
///
/// Three methods rather than one with three optional parameters: an all-optional
/// overload would be ambiguous with ``Reporter/result(broker:status:help:humanLines:)``
/// at a call site that passes only `humanLines`, and a compiler error in a
/// different file is a poor way to find that out.
extension Reporter {
    func result(assets: AssetManifest, humanLines: [String]) {
        emit(humanLines) { CLIEnvelope(ok: true, command: $0, kind: $1, assets: assets) }
    }

    func result(library: LibraryReport, humanLines: [String]) {
        emit(humanLines) { CLIEnvelope(ok: true, command: $0, kind: $1, library: library) }
    }

    func result(search: SearchReport, humanLines: [String]) {
        emit(humanLines) { CLIEnvelope(ok: true, command: $0, kind: $1, search: search) }
    }

    private func emit(_ humanLines: [String], _ envelope: (String, String) -> CLIEnvelope) {
        if json {
            Output.json(envelope(command, CLIEnvelope.Kind.result))
        } else {
            Output.lines(humanLines)
        }
    }
}
