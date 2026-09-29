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
///
/// **Debug builds only**, and it must stay that way. `/tmp` is world-writable,
/// so in a shipped build this is an unauthenticated local trigger: any process
/// under any user could touch one path and make the app photograph every
/// window it has into a world-readable file. The images carry library paths,
/// folder names and film titles (not the TMDB key, which is used but never
/// shown). The write is worse than the read — `Data.write(to:)` with no
/// options follows symlinks, so a planted symlink turns this into overwriting
/// a file of someone else's choosing, as the user running the app.
///
/// It exists because a session with no access to the window server cannot
/// screenshot anything, and that is a development problem, not a user-facing
/// feature.
@MainActor
enum WindowCapture {

    /// Off unless explicitly switched on:
    ///
    ///     defaults write co.sstools.Changeover EnableWindowCapture -bool true
    ///
    /// Shipped builds do nothing at all without it, so the poll below never
    /// starts on a machine that did not ask for this.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "EnableWindowCapture")
    }

    /// Application Support, not `/tmp`.
    ///
    /// `/tmp` is world-writable, which made the trigger an unauthenticated
    /// local one — any process under any user could ask the app to photograph
    /// itself — and made the output a symlink target, since `Data.write(to:)`
    /// without `.atomic` follows them. This directory is the user's own, so
    /// neither holds. Combined with the switch above, the capability exists
    /// only on a machine that opted in, and only for that user.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Changeover", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Touch this to ask for a capture.
    static var requestPath: String { directory.appendingPathComponent("capture-request").path }
    /// Where the images land, numbered by window.
    static var outputPrefix: String { directory.appendingPathComponent("capture").path }

    private static var timer: Timer?

    /// Start watching for requests. Polling rather than a file-system event
    /// source because the file is created and deleted constantly and a
    /// one-second poll is both simpler and impossible to get wrong.
    static func startWatching() {
        guard timer == nil, isEnabled else { return }
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
                  let png = png(of: view)
            else { continue }
            let path = "\(outputPrefix)-\(index).png"
            guard (try? png.write(to: URL(fileURLWithPath: path))) != nil else { continue }
            written.append(path)
        }
        return written
    }

    /// One window's contents as PNG data.
    ///
    /// **The layer tree, not `cacheDisplay`.** `cacheDisplay(in:to:)` walks the
    /// `NSView` draw path, and a SwiftUI window on screen is not drawn that
    /// way: its content is composited from `CALayer`s, so the bitmap came back
    /// with the AppKit-backed controls present — text fields, images, the
    /// links — and **every piece of text missing**. Captured on joe,
    /// 2026-09-29: two search boxes, two posters, two tick marks, and not one
    /// word of the headings, the runtimes, the phase row or the buttons.
    ///
    /// That made this worse than useless for judging the window, because it
    /// looked like a screenshot. It is the reason a real screenshot had to be
    /// asked for, twice, and the reason a wrong conclusion was drawn from one
    /// of these images.
    ///
    /// `CALayer.render(in:)` draws what is actually composited, text included.
    /// `cacheDisplay` stays as the fallback for a window with no layer, where
    /// it is the correct path and always was.
    private static func png(of view: NSView) -> Data? {
        if let data = layerPNG(of: view) { return data }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func layerPNG(of view: NSView) -> Data? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let pixels = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard pixels.width >= 1, pixels.height >= 1,
              let context = CGContext(
                data: nil,
                width: Int(pixels.width), height: Int(pixels.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }

        // The window's own backdrop. A layer tree renders only what it draws,
        // and SwiftUI leaves the material behind the content to the window —
        // without this the text lands on transparency and reads as black on
        // black wherever it is dark.
        context.setFillColor((view.window?.backgroundColor ?? .windowBackgroundColor)
            .usingColorSpace(.deviceRGB)?.cgColor ?? NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: pixels))

        // A CGContext's origin is bottom-left and a layer draws top-down, so
        // rendering straight in produces an upside-down window — which is
        // exactly what the first layer-rendered capture gave.
        context.translateBy(x: 0, y: pixels.height)
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)

        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
