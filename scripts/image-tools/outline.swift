import AppKit
import CoreImage
// outline <cutout.png> <scale>  -> Swift array of (x, y) points of the outer contour, multiplied by scale.
let a = CommandLine.arguments
let image = CIImage(contentsOf: URL(fileURLWithPath: a[1]))!
let factor = 4.0
let small = image.transformed(by: CGAffineTransform(scaleX: 1 / factor, y: 1 / factor))
let w = Int(small.extent.width), h = Int(small.extent.height)
var px = [UInt8](repeating: 0, count: w * h * 4)
CIContext().render(small, toBitmap: &px, rowBytes: w * 4, bounds: small.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && px[(y * w + x) * 4 + 3] > 128 }
// Moore-neighbour tracing from the topmost-leftmost pixel.
var start = (0, 0)
outer: for y in 0..<h { for x in 0..<w where inside(x, y) { start = (x, y); break outer } }
let dirs = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
var contour = [start]
var current = start
var dir = 6
repeat {
    var found = false
    for i in 0..<8 {
        let d = (dir + 6 + i) % 8
        let next = (current.0 + dirs[d].0, current.1 + dirs[d].1)
        if inside(next.0, next.1) { current = next; dir = d; found = true; break }
    }
    if !found { break }
    contour.append(current)
} while current != start && contour.count < 100000
// Douglas-Peucker simplification.
func simplify(_ pts: [(Double, Double)], _ eps: Double) -> [(Double, Double)] {
    guard pts.count > 2 else { return pts }
    let (x1, y1) = pts.first!, (x2, y2) = pts.last!
    var maxD = 0.0, index = 0
    for i in 1..<pts.count - 1 {
        let (x0, y0) = pts[i]
        let num = abs((y2 - y1) * x0 - (x2 - x1) * y0 + x2 * y1 - y2 * x1)
        let den = max(1e-9, ((y2 - y1) * (y2 - y1) + (x2 - x1) * (x2 - x1)).squareRoot())
        let d = num / den
        if d > maxD { maxD = d; index = i }
    }
    if maxD > eps { return simplify(Array(pts[0...index]), eps).dropLast() + simplify(Array(pts[index...]), eps) }
    return [pts.first!, pts.last!]
}
let scale = Double(a[2])! * factor
// Smooth the pixel staircase with a circular moving average.
let n = contour.count
let window = 4
var smooth: [(Double, Double)] = []
for i in 0..<n {
    var sx = 0.0, sy = 0.0
    for k in -window...window {
        let p = contour[(i + k + n) % n]
        sx += Double(p.0)
        sy += Double(p.1)
    }
    let count = Double(2 * window + 1)
    smooth.append((sx / count * scale, sy / count * scale))
}
// Mirror the left half so the body is symmetric.
let xs = smooth.map { point in point.0 }
let cx = (xs.min()! + xs.max()!) / 2
let crossings = (0..<n).filter { i in (smooth[i].0 - cx) * (smooth[(i + 1) % n].0 - cx) <= 0 }
let top = crossings.min { a, b in smooth[a].1 < smooth[b].1 }!
let bottom = crossings.max { a, b in smooth[a].1 < smooth[b].1 }!
// Tracing runs clockwise from the top-left, so bottom -> top walks the left side.
var left: [(Double, Double)] = []
var index = bottom
while index != top {
    left.append(smooth[index])
    index = (index + 1) % n
}
left.append(smooth[top])
let right: [(Double, Double)] = left.reversed().map { point in (2 * cx - point.0, point.1) }
let loop: [(Double, Double)] = (right + left).map { point in (point.0 + 500 - cx, point.1) }
func distance2(_ a: (Double, Double), _ b: (Double, Double)) -> Double { (a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) }
let far = loop.indices.max { a, b in distance2(loop[a], loop[0]) < distance2(loop[b], loop[0]) }!
let simple = Array(simplify(Array(loop[0...far]), 0.45).dropLast()) + simplify(Array(loop[far...]), 0.45)
print("// \(simple.count) points, centre x \(cx) moved to 500")
print(simple.map { point in String(format: "(%.1f, %.1f)", point.0, point.1) }.joined(separator: ", "))
