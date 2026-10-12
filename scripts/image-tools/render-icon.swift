import AppKit
// render-icon <in.svg> <out.png> <size>: rasterise an SVG with a transparent background.
let a = CommandLine.arguments
guard a.count == 4, let image = NSImage(contentsOf: URL(fileURLWithPath: a[1])), let size = Int(a[3]) else {
    FileHandle.standardError.write(Data("usage: render-icon <in.svg> <out.png> <size>\n".utf8))
    exit(1)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
