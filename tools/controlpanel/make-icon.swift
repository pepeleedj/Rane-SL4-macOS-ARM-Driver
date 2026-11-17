// make-icon.swift <output.iconset> — draw the SL 4 Control Panel's app icon (a four-deck SL box) at every
// size an .iconset needs. build-app.sh compiles and runs it, then turns the .iconset into AppIcon.icns
// with iconutil.
// make-icon.swift --installer-background <output.png> — the installer's background: the icon in the
// bottom-left corner of a transparent canvas the size of the installer's window, at 2x. The installer scales
// the background to its window (Installer/package/Distribution.xml), so the icon sits under the list of
// steps, clear of the text pane. Installer/build-pkg.sh runs it.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// A projective map from the unit square — u across the box from left to right, v from its front edge to its
// back edge — onto a quadrilateral, so the box's top face can be drawn flat and seen in perspective.
struct Projection {
    let a, b, c, d, e, f, g, h: CGFloat
    // p0 front left, p1 front right, p2 back right, p3 back left.
    init(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) {
        let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, dx3 = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y, dy3 = p0.y - p1.y + p2.y - p3.y
        let den = dx1 * dy2 - dx2 * dy1
        g = (dx3 * dy2 - dx2 * dy3) / den
        h = (dx1 * dy3 - dx3 * dy1) / den
        a = p1.x - p0.x + g * p1.x; b = p3.x - p0.x + h * p3.x; c = p0.x
        d = p1.y - p0.y + g * p1.y; e = p3.y - p0.y + h * p3.y; f = p0.y
    }
    func callAsFunction(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
        let w = g * u + h * v + 1
        return CGPoint(x: (a * u + b * v + c) / w, y: (d * u + e * v + f) / w)
    }
    func quad(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: [self(u0, v0), self(u1, v0), self(u1, v1), self(u0, v1)])
        path.closeSubpath()
        return path
    }
}

// A polyline in the top face's (u, v) coordinates, with rounded corners, for the lettering.
struct Strokes {
    var points: [(CGFloat, CGFloat)] = []
    mutating func line(_ u: CGFloat, _ v: CGFloat) { points.append((u, v)) }
    // A quarter turn of radius r about (cu, cv), from angle a0 to a1 (radians).
    mutating func arc(_ cu: CGFloat, _ cv: CGFloat, _ ru: CGFloat, _ rv: CGFloat, _ a0: CGFloat, _ a1: CGFloat) {
        for i in 0...8 {
            let a = a0 + (a1 - a0) * CGFloat(i) / 8
            points.append((cu + ru * cos(a), cv + rv * sin(a)))
        }
    }
    func path(_ p: Projection) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { p($0.0, $0.1) })
        return path
    }
    // The outline of these strokes, `width` wide, laid on the top face so that it narrows and foreshortens
    // with the box. The strokes are widened on a flat top face of the box's true proportions (`size`, in the
    // same units as `width`), and the outline is then projected.
    func outline(_ p: Projection, width: CGFloat, size: CGSize) -> CGPath {
        let flat = CGMutablePath()
        flat.addLines(between: points.map { CGPoint(x: $0.0 * size.width, y: $0.1 * size.height) })
        let stroked = flat.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 2)
        func project(_ q: CGPoint) -> CGPoint { p(q.x / size.width, q.y / size.height) }
        let path = CGMutablePath()
        stroked.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: path.move(to: project(e.points[0]))
            case .addLineToPoint: path.addLine(to: project(e.points[0]))
            case .addQuadCurveToPoint: path.addQuadCurve(to: project(e.points[1]), control: project(e.points[0]))
            case .addCurveToPoint:
                path.addCurve(to: project(e.points[2]), control1: project(e.points[0]), control2: project(e.points[1]))
            case .closeSubpath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

// The letters S, L and 4, wide and geometric, in a box from (u0, v0) to (u1, v1) on the top face.
func letterS(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat, _ ru: CGFloat, _ rv: CGFloat) -> Strokes {
    let vm = (v0 + v1) / 2, pi = CGFloat.pi
    var s = Strokes()
    s.line(u1, v1)
    s.arc(u0 + ru, v1 - rv, ru, rv, pi / 2, pi)
    s.arc(u0 + ru, vm + rv, ru, rv, pi, 3 * pi / 2)
    s.arc(u1 - ru, vm - rv, ru, rv, pi / 2, 0)
    s.arc(u1 - ru, v0 + rv, ru, rv, 0, -pi / 2)
    s.line(u0, v0)
    return s
}
func letterL(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat) -> Strokes {
    var s = Strokes()
    s.line(u0, v1); s.line(u0, v0); s.line(u1, v0)
    return s
}
// The 4 is two strokes: the diagonal from the top of the upright down to the crossbar and along it, and
// the upright itself, two thirds of the way across; each is filled on its own, so their overlap doesn't
// cancel out.
func letter4(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat) -> [Strokes] {
    let um = u0 + (u1 - u0) * 2 / 3, vb = v0 + (v1 - v0) * 0.3
    var diagonal = Strokes()
    diagonal.line(um, v1); diagonal.line(u0, vb); diagonal.line(u1, vb)
    var upright = Strokes()
    upright.line(um, v1); upright.line(um, v0)
    return [diagonal, upright]
}

// Draws on a 1024 × 1024 canvas, origin bottom left; the caller scales the context for other sizes.
// The picture is the SL 4, seen from above and in front: a black box with three panels on top (the outputs'
// labels, "SL4", the inputs' labels), and on its front the inputs' RCA sockets in five stacked pairs (decks
// 1-4 and Aux), the four THRU lights, the ground post over its DIP switch, and the two USB sockets (ports A
// and B) with their lights.
func drawIcon(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func gradient(_ colours: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colours as CFArray, locations: nil)!
    }

    // The background: a light rounded square on the standard macOS icon grid (824 pt inside 1024 pt).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0.85, 0.86, 0.88))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.96, 0.96, 0.97), rgb(0.78, 0.79, 0.82)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The box: its front face, and its top face in perspective above it.
    let left: CGFloat = 168, right: CGFloat = 856, frontBottom: CGFloat = 214, frontTop: CGFloat = 372
    let top = Projection(CGPoint(x: left, y: frontTop), CGPoint(x: right, y: frontTop),
                         CGPoint(x: right - 62, y: 760), CGPoint(x: left + 62, y: 760))
    let outline = CGMutablePath()
    outline.addLines(between: [CGPoint(x: left, y: frontBottom + 14), CGPoint(x: left, y: frontTop),
                               top(0, 1), top(1, 1), CGPoint(x: right, y: frontTop),
                               CGPoint(x: right, y: frontBottom + 14)])
    outline.addArc(tangent1End: CGPoint(x: right, y: frontBottom), tangent2End: CGPoint(x: left, y: frontBottom), radius: 14)
    outline.addArc(tangent1End: CGPoint(x: left, y: frontBottom), tangent2End: CGPoint(x: left, y: frontTop), radius: 14)
    outline.closeSubpath()

    // Its shadow on the background.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0, 0, 0, 0.5))
    ctx.addPath(outline)
    ctx.setFillColor(rgb(0.08, 0.08, 0.09))
    ctx.fillPath()
    ctx.restoreGState()

    // The front face.
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.17, 0.17, 0.19), rgb(0.07, 0.07, 0.08)]),
                           start: CGPoint(x: 512, y: frontTop), end: CGPoint(x: 512, y: frontBottom), options: [])
    ctx.restoreGState()

    // The top face, lighter towards the back, with a highlight along its front edge.
    ctx.saveGState()
    ctx.addPath(top.quad(0, 0, 1, 1))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.11, 0.11, 0.12), rgb(0.20, 0.20, 0.22)]),
                           start: top(0.5, 0), end: top(0.5, 1), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(1, 1, 1, 0.28))
    ctx.setLineWidth(4)
    ctx.strokeLineSegments(between: [top(0, 0), top(1, 0)])

    // The three panels, each edged where it catches the light.
    for (v0, v1) in [(CGFloat(0.04), CGFloat(0.27)), (0.31, 0.69), (0.73, 0.96)] {
        ctx.addPath(top.quad(0.03, v0, 0.97, v1))
        ctx.setFillColor(rgb(0.10, 0.10, 0.11, 0.6))
        ctx.fillPath()
        ctx.addPath(top.quad(0.03, v0, 0.97, v1))
        ctx.setStrokeColor(rgb(1, 1, 1, 0.16))
        ctx.setLineWidth(3)
        ctx.strokePath()
    }

    // The labels' brackets on the back (outputs) and front (inputs) panels: a line along the panel with a tick
    // over the middle of each socket pair (1, 2, 3, 4 and AUX), pointing away from the red label, which is on
    // the line's other side: on the back panel the ticks point back, on the front panel forwards.
    let columns: [CGFloat] = [212, 268, 336, 392, 460]   /* the RCA pairs' centres on the front, below */
    let ticks = columns.map { ($0 - left) / (right - left) }
    for (v, lift, label) in [(CGFloat(0.86), CGFloat(0.04), CGFloat(0.80)), (0.14, -0.04, 0.20)] {
        var line = Strokes()
        line.line(ticks.first!, v); line.line(ticks.last!, v)
        ctx.addPath(line.path(top))
        for u in ticks {
            var tick = Strokes()
            tick.line(u, v); tick.line(u, v + lift)
            ctx.addPath(tick.path(top))
        }
        ctx.setStrokeColor(rgb(0.92, 0.92, 0.93, 0.85))
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.addPath(top.quad(ticks[1] + 0.02, label - 0.008, ticks[3] - 0.02, label + 0.008))
        ctx.setFillColor(rgb(0.90, 0.20, 0.18))
        ctx.fillPath()
    }

    // "SL4", lying on the top face: S and L in white, 4 in red. The box is a little deeper than it is wide.
    let face = CGSize(width: 688, height: 640)
    let (v0, v1): (CGFloat, CGFloat) = (0.40, 0.60)
    let (ru, rv) = (26 / face.width, 26 / face.height)
    ctx.addPath(letterS(0.17, v0, 0.38, v1, ru, rv).outline(top, width: 16, size: face))
    ctx.addPath(letterL(0.44, v0, 0.62, v1).outline(top, width: 16, size: face))
    ctx.setFillColor(rgb(0.95, 0.95, 0.96))
    ctx.fillPath()
    ctx.setFillColor(rgb(0.90, 0.20, 0.18))
    for stroke in letter4(0.68, v0, 0.86, v1) {
        ctx.addPath(stroke.outline(top, width: 16, size: face))
        ctx.fillPath()
    }

    // On the front, the inputs: ten gold RCA sockets in five stacked pairs, left (white) above right (red),
    // grouped as decks 1-2, decks 3-4 and Aux.
    let midY = (frontBottom + frontTop) / 2
    func rca(_ x: CGFloat, _ y: CGFloat, white: Bool) {
        ctx.setFillColor(rgb(0.04, 0.04, 0.04))
        ctx.fillEllipse(in: CGRect(x: x - 25, y: y - 25, width: 50, height: 50))
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: x - 21, y: y - 21, width: 42, height: 42))
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(1.0, 0.90, 0.62), rgb(0.78, 0.58, 0.24), rgb(0.55, 0.38, 0.13)]),
                               start: CGPoint(x: x - 15, y: y + 21), end: CGPoint(x: x + 15, y: y - 21), options: [])
        ctx.restoreGState()
        ctx.setFillColor(white ? rgb(0.93, 0.93, 0.92) : rgb(0.86, 0.18, 0.16))
        ctx.fillEllipse(in: CGRect(x: x - 13, y: y - 13, width: 26, height: 26))
        ctx.setFillColor(rgb(0.05, 0.05, 0.05))
        ctx.fillEllipse(in: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
    }
    for x in columns {
        rca(x, midY + 30, white: true)
        rca(x, midY - 30, white: false)
    }

    // The four THRU lights, one above the other, lit green.
    for i in 0..<4 {
        let y = midY + 42 - CGFloat(i) * 28
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 14, color: rgb(0.25, 0.95, 0.40, 0.9))
        ctx.setFillColor(rgb(0.30, 0.88, 0.42))
        ctx.fillEllipse(in: CGRect(x: 528 - 9, y: y - 9, width: 18, height: 18))
        ctx.restoreGState()
    }

    // The ground post (a knurled gold knob) over the blue DIP switch.
    let post = CGPoint(x: 590, y: midY + 26)
    ctx.setFillColor(rgb(0.04, 0.04, 0.04))
    ctx.fillEllipse(in: CGRect(x: post.x - 30, y: post.y - 30, width: 60, height: 60))
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: post.x - 27, y: post.y - 27, width: 54, height: 54))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.98, 0.88, 0.66), rgb(0.80, 0.64, 0.38), rgb(0.55, 0.42, 0.22)]),
                           start: CGPoint(x: post.x - 20, y: post.y + 27), end: CGPoint(x: post.x + 20, y: post.y - 27),
                           options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(0.45, 0.33, 0.16, 0.8))
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: CGRect(x: post.x - 18, y: post.y - 18, width: 36, height: 36))
    let dip = CGRect(x: post.x - 26, y: midY - 58, width: 52, height: 28)
    ctx.addPath(CGPath(roundedRect: dip, cornerWidth: 3, cornerHeight: 3, transform: nil))
    ctx.setFillColor(rgb(0.22, 0.52, 0.92))
    ctx.fillPath()
    for i in 0..<4 {
        ctx.setFillColor(rgb(0.95, 0.96, 0.98))
        ctx.fill(CGRect(x: dip.minX + 6 + CGFloat(i) * 11, y: dip.minY + 6, width: 7, height: 10))
    }

    // The two USB sockets, ports A and B: orange type-B sockets, each with a blue light to its left.
    for x in [CGFloat(690), 790] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 16, color: rgb(0.30, 0.50, 1.0, 1))
        ctx.setFillColor(rgb(0.35, 0.55, 1.0))
        ctx.fillEllipse(in: CGRect(x: x - 34, y: midY - 30, width: 14, height: 14))
        ctx.restoreGState()
        let usb = CGRect(x: x - 8, y: midY - 30, width: 52, height: 48)
        ctx.addPath(CGPath(roundedRect: usb, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.setFillColor(rgb(0.93, 0.52, 0.18))
        ctx.fillPath()
        // The socket's opening: square, its top corners cut off, with the contact block inside.
        let o = usb.insetBy(dx: 9, dy: 8)
        let hole = CGMutablePath()
        hole.addLines(between: [CGPoint(x: o.minX, y: o.minY), CGPoint(x: o.maxX, y: o.minY),
                                CGPoint(x: o.maxX, y: o.maxY - 8), CGPoint(x: o.maxX - 8, y: o.maxY),
                                CGPoint(x: o.minX + 8, y: o.maxY), CGPoint(x: o.minX, y: o.maxY - 8)])
        hole.closeSubpath()
        ctx.addPath(hole)
        ctx.setFillColor(rgb(0.10, 0.07, 0.04))
        ctx.fillPath()
        ctx.setFillColor(rgb(0.85, 0.48, 0.18))
        ctx.fill(o.insetBy(dx: 9, dy: 8))
    }
}

func writePNG(pixels: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(ctx)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

/* The installer background: a 620 x 418 point canvas (the installer window's content area) at 2x, with the
   icon 150 points square, 10 points in from the bottom-left corner. */
func writeInstallerBackground(to url: URL) {
    let scale: CGFloat = 2, width = 620, height = 418, icon: CGFloat = 150, margin: CGFloat = 10
    let ctx = CGContext(data: nil, width: width * 2, height: height * 2, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.translateBy(x: margin * scale, y: margin * scale)
    ctx.scaleBy(x: icon * scale / 1024, y: icon * scale / 1024)
    drawIcon(ctx)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--installer-background" {
    writeInstallerBackground(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon <output.iconset> | --installer-background <output.png>\n".data(using: .utf8)!)
    exit(2)
}
let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
