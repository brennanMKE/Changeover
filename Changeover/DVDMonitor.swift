import AppKit

class DVDMonitor {
    /// Fired with the mounted volume's URL. The URL is what #0005 will eject,
    /// so it is carried through rather than dropped.
    var onDVDInserted: ((URL) -> Void)?

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeMounted(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
    }

    @objc nonisolated func volumeMounted(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let url  = info[NSWorkspace.volumeURLUserInfoKey] as? URL
        else { return }

        let videoTS = url.appendingPathComponent("VIDEO_TS")
        guard FileManager.default.fileExists(atPath: videoTS.path) else { return }

        Task { @MainActor [weak self] in
            self?.onDVDInserted?(url)
        }
    }
}
