// Génère l'icône (1024 px) : carré arrondi sombre Socle, bande de pellicule claire et triangle de lecture bleu.
import Cocoa
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: size - 200, height: size - 200), xRadius: 185, yRadius: 185).fill()
let blue = NSColor(srgbRed: 0x38/255, green: 0xbd/255, blue: 0xf8/255, alpha: 1)
let amber = NSColor(srgbRed: 0xfb/255, green: 0xbf/255, blue: 0x24/255, alpha: 1)
// Pellicule : bande claire avec perforations de part et d'autre
let strip = NSRect(x: 230, y: 300, width: 564, height: 424)
NSColor(white: 0.9, alpha: 1).setFill()
NSBezierPath(roundedRect: strip, xRadius: 40, yRadius: 40).fill()
NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1).setFill()
for i in 0..<5 {
    let y = strip.minY + 28 + CGFloat(i) * 78
    NSBezierPath(roundedRect: NSRect(x: strip.minX + 14, y: y, width: 34, height: 46), xRadius: 8, yRadius: 8).fill()
    NSBezierPath(roundedRect: NSRect(x: strip.maxX - 48, y: y, width: 34, height: 46), xRadius: 8, yRadius: 8).fill()
}
// Image centrale sombre et triangle de lecture
let frame = NSRect(x: strip.minX + 76, y: strip.minY + 36, width: strip.width - 152, height: strip.height - 72)
NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1).setFill()
NSBezierPath(roundedRect: frame, xRadius: 22, yRadius: 22).fill()
let cx = frame.midX + 8, cy = frame.midY
let tri = NSBezierPath()
tri.move(to: NSPoint(x: cx - 62, y: cy + 88)); tri.line(to: NSPoint(x: cx - 62, y: cy - 88)); tri.line(to: NSPoint(x: cx + 100, y: cy))
tri.close(); blue.setFill(); tri.fill()
// Repère ambre (sous-clip) sous la pellicule
amber.setFill()
NSBezierPath(roundedRect: NSRect(x: 330, y: 220, width: 364, height: 30), xRadius: 15, yRadius: 15).fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
