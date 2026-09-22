import AppKit
import Foundation

/// Changeover photographing its own windows, on request.
///
/// `screencapture` asks the window server for the framebuffer, and the window
/// server only exists inside the logged-in GUI session — so from SSH it fails
/// with "could not create image from display" whatever Screen Recording is
/// set to. That blocked every attempt to see what this app looked like on the
/// Plex host without someone walking over to it.
///
/// A process can always draw its own views. `cacheDisplay(in:to:)` renders
/// the window's content into a bitmap inside this process, needing no
/// permission, no window server capture and no console session. It is not a
/// screenshot of the screen — an overlapping window or the menu bar will not
/// appear — which is exactly right for "what does Changeover look like".
///
/// Driven by a file so it can be triggered over SSH:
///
///     ssh joe touch /tmp/changeover-capture
///
/// The request file is deleted as soon as it is seen, and the PNGs land in
/// `/tmp/changeover-capture-<n>.png`.
@MainActor
enum WindowCapture {

    /// Touch this to ask for a capture.
    static let requestPath = "/tmp/changeover-capture"
    /// Where the images land, numbered by window.
    static let outputPrefix = "/tmp/changeover-capture"

    private static var timer: Timer?

    /// Start watching for requests. Polling rather than a file-system event
    /// source because the file is created and deleted constantly and a
    /// one-second poll is both simpler and impossible to get wrong.
    static func startWatching() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard FileManager.default.fileExists(atPath: requestPath) else { return }
                try? FileManager.default.removeItem(atPath: requestPath)
                let written = captureAll()
                NSLog("Changeover: captured \(written.count) window(s): \(written.joined(separator: ", "))")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        Self.timer = timer
    }

    /// Write a PNG per visible window; returns the paths written.
    ///
    /// Only windows with content: a menu bar app's status item has a window
    /// of its own with nothing in it, and imaging that is what produced
    /// "could not create image from window" every other time this was tried.
    @discardableResult
    static func captureAll() -> [String] {
        var written: [String] = []
        for (index, window) in NSApp.windows.enumerated() {
            guard window.isVisible,
                  let view = window.contentView,
                  view.bounds.width > 1, view.bounds.height > 1,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let path = "\(outputPrefix)-\(index).png"
            guard (try? png.write(to: URL(fileURLWithPath: path))) != nil else { continue }
            written.append(path)
        }
        return written
    }
}
