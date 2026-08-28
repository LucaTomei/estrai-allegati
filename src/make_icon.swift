// Genera l'icona 1024x1024: squircle con gradiente blu, foglio bianco con righe, graffetta.
import AppKit

let size = CGFloat(1024)
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// Squircle macOS (corner ~22.4%)
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.224, yRadius: rect.height * 0.224)

// ombra
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.95, alpha: 1).setFill()
squircle.fill()
ctx.restoreGState()

// gradiente
ctx.saveGState()
squircle.addClip()
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.68, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.36, blue: 0.85, alpha: 1)
])!
grad.draw(in: rect, angle: -90)
// riflesso in alto
let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0.0)])!
gloss.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height/2), angle: 90)
ctx.restoreGState()

// foglio con angolo piegato
let px: CGFloat = 330, py: CGFloat = 250, pw: CGFloat = 364, ph: CGFloat = 480, fold: CGFloat = 96
let paper = NSBezierPath()
paper.move(to: NSPoint(x: px, y: py))
paper.line(to: NSPoint(x: px + pw, y: py))
paper.line(to: NSPoint(x: px + pw, y: py + ph - fold))
paper.line(to: NSPoint(x: px + pw - fold, y: py + ph))
paper.line(to: NSPoint(x: px, y: py + ph))
paper.close()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.30).cgColor)
NSColor.white.setFill(); paper.fill()
ctx.restoreGState()
// piega
let foldPath = NSBezierPath()
foldPath.move(to: NSPoint(x: px + pw - fold, y: py + ph))
foldPath.line(to: NSPoint(x: px + pw - fold, y: py + ph - fold))
foldPath.line(to: NSPoint(x: px + pw, y: py + ph - fold))
foldPath.close()
NSColor(calibratedWhite: 0.86, alpha: 1).setFill(); foldPath.fill()
// righe di testo
NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.90, alpha: 0.55).setFill()
for (i, w) in [220, 260, 180, 240].enumerated() {
    let y = py + ph - 170 - CGFloat(i) * 62
    NSBezierPath(roundedRect: CGRect(x: px + 52, y: y, width: CGFloat(w), height: 22), xRadius: 11, yRadius: 11).fill()
}

// graffetta (stroke arrotondato) in basso a destra, inclinata
ctx.saveGState()
ctx.translateBy(x: 700, y: 300)
ctx.rotate(by: -0.55)
let clip = NSBezierPath()
clip.lineWidth = 34; clip.lineCapStyle = .round; clip.lineJoinStyle = .round
// forma a "U" doppia
clip.move(to: NSPoint(x: -60, y: 60))
clip.line(to: NSPoint(x: -60, y: -140))
clip.appendArc(withCenter: NSPoint(x: 0, y: -140), radius: 60, startAngle: 180, endAngle: 360, clockwise: false)
clip.line(to: NSPoint(x: 60, y: 120))
clip.appendArc(withCenter: NSPoint(x: 0, y: 120), radius: 60, startAngle: 0, endAngle: 180, clockwise: false)
clip.line(to: NSPoint(x: -60, y: 120))
clip.line(to: NSPoint(x: 0, y: 120))
clip.line(to: NSPoint(x: 0, y: -100))
clip.appendArc(withCenter: NSPoint(x: 0, y: -100), radius: 0, startAngle: 0, endAngle: 0)
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.10, alpha: 1).setStroke()
clip.stroke()
ctx.restoreGState()

img.unlockFocus()
let tiff = img.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
