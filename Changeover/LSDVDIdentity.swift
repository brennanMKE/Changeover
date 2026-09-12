import Foundation

/// Optional enrichment: `lsdvd -x -Oj <mount path>` returns a stable per-disc
/// fingerprint (`dvddiscid`) that survives a remount under a different volume
/// name — verified once on hardware in #0013 (`ceaaceba983071d9a7e28fd6107947b7`
/// for the *Fargo* disc on `joe`).
///
/// `lsdvd` is **not a dependency**. It is not installed on this development
/// machine, and per #0013's Notes it must stay an optional enrichment: its
/// absence, a timeout, or a parse failure all fall back silently to
/// `OpticalDiscClassifier.fallbackDiscID` rather than blocking or failing a
/// mount.
enum LSDVDIdentity {
    /// Homebrew's two install locations (`brew install lsdvd`), checked in
    /// order. Not user-configurable — unlike `makemkvcon`/`HandBrakeCLI`,
    /// this is enrichment, not a required tool, so it doesn't warrant a
    /// Settings field.
    nonisolated static let defaultCandidatePaths = ["/opt/homebrew/bin/lsdvd", "/usr/local/bin/lsdvd"]

    /// Parses `dvddiscid` out of `lsdvd -Oj` JSON. Kept as a pure function,
    /// independent of `Process`, so the parsing logic is testable with a
    /// fixture regardless of whether `lsdvd` is installed anywhere.
    nonisolated static func parseDiscID(fromJSON data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let discID = object["dvddiscid"] as? String,
            !discID.isEmpty
        else { return nil }
        return discID
    }

    /// Runs `lsdvd -x -Oj <mountPath>` if a binary is present at one of
    /// `candidatePaths`, time-boxed so a hung or misbehaving process can't
    /// stall a disk-appeared callback. Returns `nil` on any absence, launch
    /// failure, timeout, non-zero exit, or parse failure — "identity
    /// unknown" is a normal, expected outcome here, not an error condition.
    nonisolated static func discID(
        mountPath: String,
        candidatePaths: [String] = LSDVDIdentity.defaultCandidatePaths,
        timeout: TimeInterval = 3.0
    ) -> String? {
        guard let executablePath = candidatePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-x", "-Oj", mountPath]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return parseDiscID(fromJSON: data)
    }
}
