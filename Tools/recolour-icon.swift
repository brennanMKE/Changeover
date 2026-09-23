// Take the shipping icon, keep its artwork exactly, and repaint it:
// the white film illustration becomes orange, everything else charcoal.
//
// Derived from the original pixels rather than redrawn, because the point is
// to keep the drawing the user already likes — proportions, corner radius,
// sprocket spacing and all.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let source = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let size = Int(CommandLine.arguments[3]) ?? 1024

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fatalError("could not read \(source)")
}

let w = image.width, h = image.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
guard let readCtx = CGContext(data: &pixels, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no read context")
}
readCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

// Charcoal and orange, exactly Curator's.
let bg: (UInt8, UInt8, UInt8) = (44, 44, 47)
let fg: (UInt8, UInt8, UInt8) = (229, 160, 13)

var outPixels = [UInt8](repeating: 0, count: w * h * 4)
for i in stride(from: 0, to: w * h * 4, by: 4) {
    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
    let a = pixels[i + 3]
    // Outside the rounded square the original is transparent; keep it so.
    guard a > 8 else { outPixels[i + 3] = 0; continue }
    // The illustration is the only pure-white thing in the artwork. The
    // gradient's palest point is a warm cream, so requiring all three
    // channels high *and* near-neutral separates them cleanly.
    let minC = min(r, min(g, b)), maxC = max(r, max(g, b))
    // Full opacity too: the original carries a soft near-white outer glow
    // outside the rounded square, which passes the colour test and would
    // otherwise come back as an orange rim around the whole icon.
    let isArtwork = minC > 205 && (maxC - minC) < 26 && a > 250
    let c = isArtwork ? fg : bg
    outPixels[i] = c.0; outPixels[i + 1] = c.1; outPixels[i + 2] = c.2
    outPixels[i + 3] = a
}

guard let writeCtx = CGContext(data: &outPixels, width: w, height: h,
                               bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let recoloured = writeCtx.makeImage() else { fatalError("no write context") }

// Scale to the requested size.
guard let scaleCtx = CGContext(data: nil, width: size, height: size,
                               bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no scale context")
}
scaleCtx.interpolationQuality = .high
scaleCtx.draw(recoloured, in: CGRect(x: 0, y: 0, width: size, height: size))
guard let final = scaleCtx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    fatalError("no destination")
}
CGImageDestinationAddImage(dest, final, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out) at \(size)")
