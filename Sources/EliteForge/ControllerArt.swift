import EliteKit
import SwiftUI

/// Drawing of the Elite Series 2. The body outline is traced from a photo of
/// the controller ("Xbox One Elite Wireless Controller Series 2 (Model 1797)"
/// by mliu92, CC BY-SA 2.0) and made symmetric; controls sit where they are on
/// the real controller. Pressed controls light up green, the control selected
/// in the editor is outlined in blue.
struct EliteControllerArt: View {
    /// Layout space: the body is 1000 x 716.5, below a strip for the triggers
    /// and above a margin that keeps the drop shadow from being clipped.
    static let bodyTop: CGFloat = 64
    static let shadowMargin: CGFloat = 44
    static let size = CGSize(width: 1000, height: 716.5 + bodyTop + shadowMargin)

    var input = InputState()
    var highlighted: Set<RemappableControl> = []
    /// Xbox button brightness, 0-100.
    var brightness: Double = 100
    /// Profile light colour; nil is the default white.
    var lightColor: LightColor?
    var showPaddles = true

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / Self.size.width, size.height / Self.size.height)
            context.translateBy(x: (size.width - Self.size.width * scale) / 2, y: (size.height - Self.size.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            draw(in: &context)
        }
        .aspectRatio(Self.size, contentMode: .fit)
        .accessibilityLabel("Xbox Elite Series 2 controller")
    }

    // MARK: Layout (body coordinates)

    static let guide = CGPoint(x: 500, y: 107.5)
    static let leftStick = CGPoint(x: 220, y: 216)
    static let rightStick = CGPoint(x: 656.5, y: 386.5)
    /// Mirrors the right stick, as on the real controller.
    static let dpad = CGPoint(x: 343.5, y: 386.5)
    static let view = CGPoint(x: 420, y: 220)
    static let menu = CGPoint(x: 580, y: 220)
    static let profileButton = CGPoint(x: 500, y: 274)
    static let profileLEDs: [CGPoint] = [CGPoint(x: 500, y: 380), CGPoint(x: 500, y: 397.5), CGPoint(x: 500, y: 415)]

    /// Where each control sits in layout space, for callout lines.
    static func anchor(_ control: RemappableControl) -> CGPoint {
        if let trigger = triggerCenter(control) { return trigger }
        let point = bodyAnchor(control)
        return CGPoint(x: point.x, y: point.y + bodyTop)
    }

    /// Triggers, drawn in the strip above the body.
    static func triggerCenter(_ control: RemappableControl) -> CGPoint? {
        switch control {
        case .leftTrigger: CGPoint(x: 240, y: 66)
        case .rightTrigger: CGPoint(x: 760, y: 66)
        default: nil
        }
    }

    static func bodyAnchor(_ control: RemappableControl) -> CGPoint {
        switch control {
        case .a: CGPoint(x: 790.5, y: 295)
        case .b: CGPoint(x: 861.5, y: 222.5)
        case .x: CGPoint(x: 716.5, y: 222.5)
        case .y: CGPoint(x: 790.5, y: 150)
        case .dpadUp: CGPoint(x: dpad.x, y: dpad.y - 45)
        case .dpadDown: CGPoint(x: dpad.x, y: dpad.y + 45)
        case .dpadLeft: CGPoint(x: dpad.x - 45, y: dpad.y)
        case .dpadRight: CGPoint(x: dpad.x + 45, y: dpad.y)
        case .leftBumper: CGPoint(x: 205, y: 62)
        case .rightBumper: CGPoint(x: 795, y: 62)
        case .leftTrigger: CGPoint(x: 240, y: 2)
        case .rightTrigger: CGPoint(x: 760, y: 2)
        case .leftStick: leftStick
        case .rightStick: rightStick
        case .paddleUpperLeft: CGPoint(x: 344, y: 564 + paddleDrop)
        case .paddleLowerLeft: CGPoint(x: 344, y: 618 + paddleDrop)
        case .paddleUpperRight: CGPoint(x: 656, y: 564 + paddleDrop)
        case .paddleLowerRight: CGPoint(x: 656, y: 618 + paddleDrop)
        }
    }

    // MARK: State

    private func pressed(_ control: RemappableControl) -> Bool { input.isPressed(control) }

    private func selected(_ control: RemappableControl) -> Bool { highlighted.contains(control) }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext) {
        drawTrigger(&context, .leftTrigger)
        drawTrigger(&context, .rightTrigger)

        context.translateBy(x: 0, y: Self.bodyTop)
        let body = Self.bodyPath
        if showPaddles { drawPaddles(&context) }

        // Shadow, then the matte body.
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.75), radius: 28, x: 0, y: 20))
            layer.fill(body, with: .color(Color(white: 0.12)))
        }
        context.fill(body, with: .linearGradient(Gradient(colors: [Color(white: 0.23), Color(white: 0.15), Color(white: 0.10)]),
                                                 startPoint: CGPoint(x: 500, y: 40), endPoint: CGPoint(x: 500, y: 690)))

        // Silver shoulders and top strip.
        var silver = context
        silver.clip(to: body)
        silver.clip(to: Self.shoulderRegion)
        silver.fill(Path(CGRect(x: 0, y: 0, width: 1000, height: 200)),
                    with: .linearGradient(Gradient(colors: [Color(white: 0.86), Color(white: 0.62), Color(white: 0.40)]), startPoint: CGPoint(x: 500, y: 18), endPoint: CGPoint(x: 500, y: 110)))
        for control in [RemappableControl.leftBumper, .rightBumper] {
            var bumper = silver
            bumper.clip(to: Path(CGRect(x: control == .leftBumper ? 0 : 640, y: 0, width: 360, height: 200)))
            if pressed(control) { bumper.fill(Path(CGRect(x: 0, y: 0, width: 1000, height: 200)), with: .color(Color.xboxGlow.opacity(0.75))) }
            if selected(control) { bumper.fill(Path(CGRect(x: 0, y: 0, width: 1000, height: 200)), with: .color(Color.selection.opacity(0.45))) }
        }
        var edges = context
        edges.clip(to: body)
        edges.stroke(Self.shoulderEdge, with: .color(.black.opacity(0.55)), lineWidth: 2.5)

        // Rubber grips with a knurled texture.
        var grips = context
        grips.clip(to: body)
        grips.clip(to: Self.gripRegion)
        grips.fill(Path(CGRect(x: 0, y: 0, width: 1000, height: 720)),
                   with: .linearGradient(Gradient(colors: [Color(white: 0.13), Color(white: 0.07)]), startPoint: CGPoint(x: 500, y: 250), endPoint: CGPoint(x: 500, y: 700)))
        grips.stroke(Self.knurl, with: .color(.white.opacity(0.07)), lineWidth: 1)
        edges.stroke(Self.gripEdges, with: .color(.black.opacity(0.6)), lineWidth: 2)

        // Raised top panel edge and the body rim.
        context.stroke(Self.panelEdge, with: .color(.white.opacity(0.07)), lineWidth: 2)
        context.stroke(body, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.04)]), startPoint: CGPoint(x: 500, y: 20), endPoint: CGPoint(x: 500, y: 500)), lineWidth: 2)

        drawStick(&context, center: Self.leftStick, x: input.leftStickX, y: input.leftStickY, control: .leftStick)
        drawStick(&context, center: Self.rightStick, x: input.rightStickX, y: input.rightStickY, control: .rightStick)
        drawDpad(&context)

        for (control, letter) in [(RemappableControl.y, "Y"), (.x, "X"), (.b, "B"), (.a, "A")] {
            drawGlossyButton(&context, center: Self.bodyAnchor(control), radius: 34, pressed: pressed(control), selected: selected(control)) { context, center in
                var text = context.resolve(Text(letter).font(.system(size: 34, weight: .semibold, design: .default)))
                text.shading = .color(pressed(control) ? .white : Color(white: 0.6))
                context.draw(text, at: center)
            }
        }
        for (point, button, symbol) in [(Self.view, InputButton.view, "rectangle.on.rectangle"), (Self.menu, InputButton.menu, "line.3.horizontal")] {
            drawGlossyButton(&context, center: point, radius: 22, pressed: input.buttons.contains(button), selected: false) { context, center in
                var glyph = context.resolve(Image(systemName: symbol))
                glyph.shading = .color(.white.opacity(0.75))
                context.draw(glyph, at: center)
            }
        }
        context.fill(Path(ellipseIn: CGRect(x: 497, y: 217, width: 6, height: 6)), with: .color(.black.opacity(0.8)))

        // Profile button and LEDs.
        let pill = Path(roundedRect: CGRect(x: Self.profileButton.x - 27, y: Self.profileButton.y - 11, width: 54, height: 22), cornerRadius: 11)
        context.fill(pill, with: .linearGradient(Gradient(colors: [Color(white: 0.22), Color(white: 0.04)]), startPoint: CGPoint(x: 500, y: 263), endPoint: CGPoint(x: 500, y: 285)))
        context.stroke(pill, with: .color(.white.opacity(0.15)), lineWidth: 1)
        for (index, point) in Self.profileLEDs.enumerated() {
            let dash = Path(roundedRect: CGRect(x: point.x - 13, y: point.y - 3.5, width: 26, height: 7), cornerRadius: 3.5)
            if (input.activeSlot ?? 0) > index {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: .white, radius: 6))
                    layer.fill(dash, with: .color(.white))
                }
            } else {
                context.fill(dash, with: .color(Color(white: 0.06)))
                context.stroke(dash, with: .color(.white.opacity(0.14)), lineWidth: 1)
            }
        }

        drawGuide(&context)

    }

    /// The back paddles, traced from a photo of the controller's back and
    /// mirrored to the front view. They hang below the body between the grips,
    /// where their tips show on the real controller.
    private func drawPaddles(_ context: inout GraphicsContext) {
        let labels: [(RemappableControl, String)] = [(.paddleUpperRight, "P1"), (.paddleLowerRight, "P2"), (.paddleUpperLeft, "P3"), (.paddleLowerLeft, "P4")]
        for (control, label) in labels {
            let path = Self.paddlePath(control)
            let center = Self.bodyAnchor(control)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.7), radius: 6, x: 0, y: 4))
                layer.fill(path, with: .linearGradient(Gradient(colors: [Color(white: 0.62), Color(white: 0.40), Color(white: 0.26)]),
                                                       startPoint: CGPoint(x: center.x, y: center.y - 20), endPoint: CGPoint(x: center.x, y: center.y + 60)))
            }
            mark(&context, path, pressed: pressed(control), selected: selected(control)) { context in
                context.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 1)
            }
            var text = context.resolve(Text(label).font(.system(size: 13, weight: .bold, design: .rounded)))
            text.shading = .color(pressed(control) ? .white : Color(white: 0.15))
            context.draw(text, at: center)
        }
    }

    /// How far below their traced position the paddles are drawn, so the body doesn't cover them.
    static let paddleDrop: CGFloat = 24

    static func paddlePath(_ control: RemappableControl) -> Path {
        // Right-side shapes; the left pair is mirrored.
        var path: Path
        switch control {
        case .paddleUpperRight, .paddleUpperLeft:
            path = Path(roundedRect: CGRect(x: 590, y: 550, width: 132, height: 28), cornerRadius: 12)
            var hook = Path()
            hook.move(to: CGPoint(x: 712, y: 562))
            hook.addQuadCurve(to: CGPoint(x: 734, y: 588), control: CGPoint(x: 730, y: 566))
            path = path.union(hook.strokedPath(StrokeStyle(lineWidth: 18, lineCap: .round)))
        default:
            // Starts below the upper paddle's hook so the two never overlap.
            path = Path(roundedRect: CGRect(x: 592, y: 604, width: 128, height: 28), cornerRadius: 12)
            var arm = Path()
            arm.move(to: CGPoint(x: 704, y: 618))
            arm.addQuadCurve(to: CGPoint(x: 752, y: 698), control: CGPoint(x: 726, y: 648))
            path = path.union(arm.strokedPath(StrokeStyle(lineWidth: 28, lineCap: .round)))
        }
        path = path.applying(CGAffineTransform(translationX: 0, y: paddleDrop))
        if control == .paddleUpperLeft || control == .paddleLowerLeft {
            path = path.applying(CGAffineTransform(translationX: 1000, y: 0).scaledBy(x: -1, y: 1))
        }
        return path
    }

    /// Fills `path` green when pressed, outlines it blue when selected, or
    /// draws the idle look.
    private func mark(_ context: inout GraphicsContext, _ path: Path, pressed: Bool, selected: Bool, idle: (inout GraphicsContext) -> Void) {
        if pressed {
            var glow = context
            glow.blendMode = .plusLighter
            glow.drawLayer { layer in
                layer.addFilter(.blur(radius: 6))
                layer.fill(path, with: .color(Color.xboxGlow.opacity(0.6)))
            }
            context.fill(path, with: .color(Color.xboxGlow.opacity(0.55)))
        } else {
            idle(&context)
        }
        if selected {
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: Color.selection, radius: 8))
                layer.stroke(path, with: .color(Color.selection), lineWidth: 3.5)
            }
        } else if pressed {
            context.stroke(path, with: .color(Color.xboxGlow), lineWidth: 2.5)
        }
    }

    private func drawGlossyButton(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, pressed: Bool, selected: Bool, label: (inout GraphicsContext, CGPoint) -> Void) {
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 3))
            layer.fill(circle, with: .radialGradient(Gradient(colors: [Color(white: 0.24), Color(white: 0.06), Color(white: 0.02)]),
                                                     center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.35), startRadius: 1, endRadius: radius * 1.3))
        }
        // Gloss highlight.
        let gloss = Path(ellipseIn: CGRect(x: center.x - radius * 0.62, y: center.y - radius * 0.86, width: radius * 1.24, height: radius * 0.7))
        context.fill(gloss, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.22), .clear]), startPoint: CGPoint(x: center.x, y: center.y - radius * 0.86), endPoint: CGPoint(x: center.x, y: center.y - radius * 0.1)))
        mark(&context, circle, pressed: pressed, selected: selected) { context in
            context.stroke(circle, with: .color(.white.opacity(0.12)), lineWidth: 1)
        }
        label(&context, center)
    }

    private func drawStick(_ context: inout GraphicsContext, center: CGPoint, x: Int16, y: Int16, control: RemappableControl) {
        let well = Path(ellipseIn: CGRect(x: center.x - 82, y: center.y - 82, width: 164, height: 164))
        context.fill(well, with: .radialGradient(Gradient(colors: [Color(white: 0.02), Color(white: 0.10)]), center: center, startRadius: 50, endRadius: 82))
        context.stroke(well, with: .color(.white.opacity(0.10)), lineWidth: 1.5)
        let offset = CGPoint(x: CGFloat(x) / 32768 * 18, y: -CGFloat(y) / 32768 * 18)
        let cap = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
        let ring = Path(ellipseIn: CGRect(x: cap.x - 64, y: cap.y - 64, width: 128, height: 128))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.7), radius: 8, x: 0, y: 6))
            layer.fill(ring, with: .radialGradient(Gradient(colors: [Color(white: 0.26), Color(white: 0.12)]), center: CGPoint(x: cap.x - 16, y: cap.y - 20), startRadius: 4, endRadius: 80))
        }
        // Knurled rim: fine radial ticks.
        var knurl = Path()
        for step in 0..<72 {
            let angle = Double(step) * .pi / 36
            knurl.move(to: CGPoint(x: cap.x + 50 * cos(angle), y: cap.y + 50 * sin(angle)))
            knurl.addLine(to: CGPoint(x: cap.x + 63 * cos(angle), y: cap.y + 63 * sin(angle)))
        }
        context.stroke(knurl, with: .color(.black.opacity(0.35)), lineWidth: 1.2)
        let top = Path(ellipseIn: CGRect(x: cap.x - 44, y: cap.y - 44, width: 88, height: 88))
        context.fill(top, with: .radialGradient(Gradient(colors: [Color(white: 0.14), Color(white: 0.24)]), center: cap, startRadius: 2, endRadius: 46))
        context.stroke(top, with: .color(.black.opacity(0.45)), lineWidth: 2)
        mark(&context, ring, pressed: pressed(control), selected: selected(control)) { context in
            context.stroke(ring, with: .color(.white.opacity(0.13)), lineWidth: 1.2)
        }
        if abs(offset.x) > 0.8 || abs(offset.y) > 0.8 {
            let dot = Path(ellipseIn: CGRect(x: cap.x - 7, y: cap.y - 7, width: 14, height: 14))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: Color.xboxGlow, radius: 6))
                layer.fill(dot, with: .color(Color.xboxGlow))
            }
        }
    }

    private func drawDpad(_ context: inout GraphicsContext) {
        let c = Self.dpad
        let dish = Path(ellipseIn: CGRect(x: c.x - 82, y: c.y - 82, width: 164, height: 164))
        context.fill(dish, with: .radialGradient(Gradient(colors: [Color(white: 0.09), Color(white: 0.15)]), center: c, startRadius: 26, endRadius: 82))
        context.stroke(dish, with: .color(.white.opacity(0.08)), lineWidth: 1.5)
        var ticks = Path()
        for step in 0..<16 {
            let angle = Double(step) * .pi / 8
            ticks.move(to: CGPoint(x: c.x + 88 * cos(angle), y: c.y + 88 * sin(angle)))
            ticks.addLine(to: CGPoint(x: c.x + (step % 4 == 0 ? 101 : 96) * cos(angle), y: c.y + (step % 4 == 0 ? 101 : 96) * sin(angle)))
        }
        context.stroke(ticks, with: .color(.white.opacity(0.32)), lineWidth: 1.6)

        // Plus-shaped metal pad.
        let arm: CGFloat = 25, span: CGFloat = 70
        var plus = Path()
        plus.addRoundedRect(in: CGRect(x: c.x - arm, y: c.y - span, width: arm * 2, height: span * 2), cornerSize: CGSize(width: 12, height: 12))
        plus.addRoundedRect(in: CGRect(x: c.x - span, y: c.y - arm, width: span * 2, height: arm * 2), cornerSize: CGSize(width: 12, height: 12))
        let pad = plus.union(Path())
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.75), radius: 6, x: 0, y: 4))
            layer.fill(pad, with: .linearGradient(Gradient(colors: [Color(white: 0.52), Color(white: 0.34), Color(white: 0.24)]), startPoint: CGPoint(x: c.x - 40, y: c.y - span), endPoint: CGPoint(x: c.x + 40, y: c.y + span)))
        }
        context.stroke(pad, with: .color(.white.opacity(0.25)), lineWidth: 1.2)
        for control in [RemappableControl.dpadUp, .dpadDown, .dpadLeft, .dpadRight] {
            let anchor = Self.bodyAnchor(control)
            let vertical = control == .dpadUp || control == .dpadDown
            let rect = CGRect(x: anchor.x - (vertical ? arm : 25), y: anchor.y - (vertical ? 25 : arm), width: vertical ? arm * 2 : 50, height: vertical ? 50 : arm * 2)
            let segment = Path(roundedRect: rect, cornerRadius: 10)
            mark(&context, segment, pressed: pressed(control), selected: selected(control)) { _ in }
        }
    }

    private func drawGuide(_ context: inout GraphicsContext) {
        let c = Self.guide
        let level = max(0.1, min(brightness, 100) / 100)
        let light = lightColor.map { Color(red: Double($0.red) / 255, green: Double($0.green) / 255, blue: Double($0.blue) / 255) } ?? .white
        var halo = context
        halo.blendMode = .plusLighter
        halo.drawLayer { layer in
            layer.addFilter(.blur(radius: 16))
            layer.fill(Path(ellipseIn: CGRect(x: c.x - 54, y: c.y - 54, width: 108, height: 108)), with: .color(light.opacity(0.45 * level)))
        }
        let button = Path(ellipseIn: CGRect(x: c.x - 41, y: c.y - 41, width: 82, height: 82))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 3))
            layer.fill(button, with: .radialGradient(Gradient(colors: [Color(white: 0.25), Color(white: 0.05)]), center: CGPoint(x: c.x - 12, y: c.y - 14), startRadius: 2, endRadius: 56))
        }
        context.stroke(button, with: .color(.white.opacity(0.14)), lineWidth: 1.2)
        let logo = XboxLogo().path(in: CGRect(x: c.x - 27, y: c.y - 27, width: 54, height: 54))
        let logoColor = input.buttons.contains(.guide) ? Color.xboxGlow : light.opacity(0.4 + 0.6 * level)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: logoColor, radius: 8 * level))
            layer.fill(logo, with: .color(logoColor))
        }
    }

    private func drawTrigger(_ context: inout GraphicsContext, _ control: RemappableControl) {
        guard let center = Self.triggerCenter(control) else { return }
        let left = control == .leftTrigger
        let pull = Double(min(left ? input.leftTrigger : input.rightTrigger, 1023)) / 1023
        var shape = Path()
        shape.move(to: CGPoint(x: -88, y: 32))
        shape.addLine(to: CGPoint(x: -80, y: -14))
        shape.addQuadCurve(to: CGPoint(x: 70, y: -26), control: CGPoint(x: -10, y: -38))
        shape.addQuadCurve(to: CGPoint(x: 88, y: 32), control: CGPoint(x: 94, y: -8))
        shape.closeSubpath()
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: (left ? -7 : 7) * .pi / 180)
        if !left { transform = transform.scaledBy(x: -1, y: 1) }
        let path = shape.applying(transform)
        context.fill(path, with: .linearGradient(Gradient(colors: [Color(white: 0.30), Color(white: 0.13), Color(white: 0.07)]),
                                                 startPoint: CGPoint(x: center.x, y: center.y - 30), endPoint: CGPoint(x: center.x, y: center.y + 30)))
        if pull > 0.01 {
            var fill = context
            fill.clip(to: path)
            let height: CGFloat = 72 * pull
            fill.fill(Path(CGRect(x: center.x - 100, y: center.y + 36 - height, width: 200, height: height)),
                      with: .linearGradient(Gradient(colors: [Color.xboxGlow, Color.xbox]), startPoint: CGPoint(x: center.x, y: center.y - 30), endPoint: CGPoint(x: center.x, y: center.y + 36)))
        }
        if selected(control) {
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: Color.selection, radius: 8))
                layer.stroke(path, with: .color(Color.selection), lineWidth: 3.5)
            }
        } else {
            context.stroke(path, with: .color(pull > 0.06 ? Color.xboxGlow : .white.opacity(0.18)), lineWidth: pull > 0.06 ? 2.5 : 1.5)
        }
        var label = context.resolve(Text(left ? "LT" : "RT").font(.system(size: 20, weight: .bold, design: .rounded)))
        label.shading = .color(pull > 0.5 ? .white : .white.opacity(0.55))
        context.draw(label, at: CGPoint(x: center.x + (left ? -10 : 10), y: center.y - 8))
    }

    // MARK: Shapes

    /// Body silhouette, traced from the photo and mirrored about x = 500.
    static let outline: [(CGFloat, CGFloat)] = [
        (501.9, 46.0), (631.9, 46.0), (637.9, 45.3), (651.9, 40.7), (679.9, 26.7), (687.9, 24.0), (695.7, 22.7), (701.0, 22.7),
        (717.9, 25.1), (743.9, 30.7), (755.9, 34.0), (781.9, 43.1), (793.9, 48.4), (805.9, 55.1), (815.9, 61.8), (827.2, 72.0),
        (840.6, 92.0), (859.2, 112.0), (874.3, 130.0), (880.3, 140.0), (883.0, 146.0), (904.6, 206.0), (919.9, 252.0), (933.7, 298.0),
        (949.4, 356.0), (964.6, 424.0), (968.3, 450.0), (971.9, 482.0), (971.9, 492.0), (973.9, 510.0), (973.9, 538.0), (970.6, 572.0),
        (965.4, 596.0), (961.0, 610.0), (951.4, 630.0), (943.9, 642.0), (931.9, 656.0), (923.9, 663.1), (915.9, 668.9), (907.9, 673.6),
        (891.9, 680.7), (875.9, 685.6), (867.9, 686.7), (859.9, 684.7), (843.9, 673.1), (823.9, 654.0), (802.8, 630.0), (774.6, 594.0),
        (763.9, 582.7), (753.9, 573.8), (739.9, 562.2), (725.9, 553.1), (713.9, 546.9), (699.9, 543.1), (667.9, 540.0), (599.9, 540.0),
        (581.9, 538.0), (418.1, 538.0), (400.1, 540.0), (332.1, 540.0), (300.1, 543.1), (290.1, 545.6), (280.1, 549.8), (260.1, 562.2),
        (246.1, 573.8), (230.8, 588.0), (217.2, 604.0), (197.2, 630.0), (176.1, 654.0), (156.1, 673.1), (140.1, 684.7), (134.1, 686.4),
        (130.1, 686.7), (118.1, 684.0), (108.1, 680.7), (96.1, 675.6), (80.1, 666.2), (68.1, 656.0), (59.2, 646.0), (50.8, 634.0),
        (39.0, 610.0), (34.6, 596.0), (29.4, 572.0), (26.1, 538.0), (26.1, 510.0), (28.1, 492.0), (28.1, 482.0), (31.7, 450.0),
        (35.4, 424.0), (50.6, 356.0), (58.6, 326.0), (80.1, 252.0), (95.4, 206.0), (117.0, 146.0), (119.7, 140.0), (125.7, 130.0),
        (140.8, 112.0), (159.4, 92.0), (172.8, 72.0), (184.1, 61.8), (194.1, 55.1), (206.1, 48.4), (218.1, 43.1), (244.1, 34.0),
        (256.1, 30.7), (282.1, 25.1), (299.0, 22.7), (304.3, 22.7), (312.1, 24.0), (320.1, 26.7), (346.1, 39.8), (354.1, 43.1),
        (362.1, 45.3), (368.1, 46.0), (498.1, 46.0),
    ]

    /// Smooth closed path through the outline points (Catmull-Rom).
    static let bodyPath: Path = {
        let p = outline.map { CGPoint(x: $0.0, y: $0.1) }
        var path = Path()
        path.move(to: p[0])
        for i in 0..<p.count {
            let p0 = p[(i - 1 + p.count) % p.count], p1 = p[i], p2 = p[(i + 1) % p.count], p3 = p[(i + 2) % p.count]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }()

    /// Where the silver shoulders meet the black body, left half; mirrored for the right.
    static let shoulderCurve: [CGPoint] = [CGPoint(x: 30, y: 190), CGPoint(x: 92, y: 118), CGPoint(x: 160, y: 80), CGPoint(x: 250, y: 58), CGPoint(x: 352, y: 50), CGPoint(x: 500, y: 52)]

    static let shoulderEdge: Path = {
        var path = Path()
        let points = shoulderCurve + shoulderCurve.reversed().dropFirst().map { CGPoint(x: 1000 - $0.x, y: $0.y) }
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }()

    static let shoulderRegion: Path = {
        var path = shoulderEdge
        path.addLine(to: CGPoint(x: 1000, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.closeSubpath()
        return path
    }()

    /// Rubber grips: everything outside the line from the upper outer edge to the inner bottom.
    static let gripRegion: Path = {
        var path = Path()
        path.addLines([CGPoint(x: -10, y: 230), CGPoint(x: 74, y: 268), CGPoint(x: 160, y: 380), CGPoint(x: 284, y: 548), CGPoint(x: 284, y: 730), CGPoint(x: -10, y: 730)])
        path.closeSubpath()
        path.addLines([CGPoint(x: 1010, y: 230), CGPoint(x: 926, y: 268), CGPoint(x: 840, y: 380), CGPoint(x: 716, y: 548), CGPoint(x: 716, y: 730), CGPoint(x: 1010, y: 730)])
        path.closeSubpath()
        return path
    }()

    static let gripEdges: Path = {
        var path = Path()
        path.addLines([CGPoint(x: 60, y: 262), CGPoint(x: 74, y: 268), CGPoint(x: 160, y: 380), CGPoint(x: 284, y: 548)])
        path.addLines([CGPoint(x: 940, y: 262), CGPoint(x: 926, y: 268), CGPoint(x: 840, y: 380), CGPoint(x: 716, y: 548)])
        return path
    }()

    static let knurl: Path = {
        var path = Path()
        var offset: CGFloat = -720
        while offset < 1000 {
            path.move(to: CGPoint(x: offset, y: 0))
            path.addLine(to: CGPoint(x: offset + 720, y: 720))
            path.move(to: CGPoint(x: offset + 720, y: 0))
            path.addLine(to: CGPoint(x: offset, y: 720))
            offset += 7
        }
        return path
    }()

    /// The edge of the raised panel around the Xbox button.
    static let panelEdge: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 168, y: 92))
        path.addCurve(to: CGPoint(x: 360, y: 164), control1: CGPoint(x: 250, y: 100), control2: CGPoint(x: 300, y: 160))
        path.addLine(to: CGPoint(x: 640, y: 164))
        path.addCurve(to: CGPoint(x: 832, y: 92), control1: CGPoint(x: 700, y: 160), control2: CGPoint(x: 750, y: 100))
        return path
    }()
}
