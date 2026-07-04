import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// macOS icon grid: content inset ~10%, corner radius ~22.37% of size
let inset: CGFloat = size * 0.10
let rect = NSRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let radius = rect.width * 0.2237
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),  // claude terracotta
    NSColor(calibratedRed: 0.72, green: 0.32, blue: 0.22, alpha: 1),
])!
gradient.draw(in: path, angle: -90)

// White gauge symbol, centered
if let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)?
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 460, weight: .medium)) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let s = tinted.size
    tinted.draw(in: NSRect(x: (size - s.width)/2, y: (size - s.height)/2, width: s.width, height: s.height))
}
img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "Assets/icon-1024.png"))
print("wrote Assets/icon-1024.png")
