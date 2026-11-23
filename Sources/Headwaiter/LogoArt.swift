import AppKit
import SwiftUI

// Logo concepts for Headwaiter, drawn as vector shapes so they render crisply at every icon
// size. `HW_LOGOS=<dir>` renders each concept at 1024 px plus a sheet with small sizes and
// the matching menu bar glyph. The chosen one becomes the app icon.

// MARK: - Shapes (drawn in a unit square, scaled to the rect)

/// A bow tie: two flared wings and a knot.
struct BowTieShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        for side in [-1.0, 1.0] as [CGFloat] {
            func sx(_ x: CGFloat) -> CGFloat { 0.5 + side * (0.5 - x) }
            path.move(to: p(sx(0.40), 0.36))
            path.addQuadCurve(to: p(sx(0.06), 0.06), control: p(sx(0.22), 0.14))
            path.addQuadCurve(to: p(sx(0.06), 0.94), control: p(sx(-0.04), 0.50))
            path.addQuadCurve(to: p(sx(0.40), 0.64), control: p(sx(0.22), 0.86))
            path.closeSubpath()
        }
        path.addRoundedRect(in: CGRect(x: r.minX + 0.38 * r.width, y: r.minY + 0.30 * r.height,
                                       width: 0.24 * r.width, height: 0.40 * r.height),
                            cornerSize: CGSize(width: 0.06 * r.width, height: 0.06 * r.width))
        return path
    }
}

/// A serving cloche: dome, knob and plate.
struct ClocheShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var path = Path()
        let base = r.minY + 0.80 * h
        let radius = 0.40 * w
        path.addArc(center: CGPoint(x: r.midX, y: base), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: r.midX - 0.07 * w, y: base - radius - 0.11 * w, width: 0.14 * w, height: 0.14 * w))
        path.addRoundedRect(in: CGRect(x: r.minX + 0.02 * w, y: base + 0.02 * h, width: 0.96 * w, height: 0.08 * h),
                            cornerSize: CGSize(width: 0.04 * h, height: 0.04 * h))
        return path
    }
}

/// Three rack units with status lights.
struct RackShape: Shape {
    var units = 3
    func path(in r: CGRect) -> Path {
        var path = Path()
        let gap = r.height * 0.07
        let unitH = (r.height - gap * CGFloat(units - 1)) / CGFloat(units)
        for i in 0..<units {
            let y = r.minY + CGFloat(i) * (unitH + gap)
            let unit = CGRect(x: r.minX, y: y, width: r.width, height: unitH)
            path.addRoundedRect(in: unit, cornerSize: CGSize(width: unitH * 0.22, height: unitH * 0.22))
        }
        return path
    }
}

/// Lights and slots cut out of the rack units (drawn in the background color).
struct RackDetailShape: Shape {
    var units = 3
    func path(in r: CGRect) -> Path {
        var path = Path()
        let gap = r.height * 0.07
        let unitH = (r.height - gap * CGFloat(units - 1)) / CGFloat(units)
        for i in 0..<units {
            let y = r.minY + CGFloat(i) * (unitH + gap)
            let d = unitH * 0.26
            for j in 0..<2 {
                path.addEllipse(in: CGRect(x: r.maxX - unitH * 0.42 - CGFloat(j) * d * 1.6, y: y + (unitH - d) / 2,
                                           width: d, height: d))
            }
            path.addRoundedRect(in: CGRect(x: r.minX + unitH * 0.32, y: y + unitH * 0.43,
                                           width: r.width * 0.36, height: unitH * 0.14),
                                cornerSize: CGSize(width: unitH * 0.07, height: unitH * 0.07))
        }
        return path
    }
}

// MARK: - Icon concepts (1024 × 1024, macOS squircle grid)

/// The standard macOS icon plate: 824 pt rounded square on a 1024 canvas, with a soft shadow.
struct IconPlate<Content: View>: View {
    let fill: AnyShapeStyle
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 3))
                .shadow(color: .black.opacity(0.28), radius: 24, y: 14)
            content
        }
        .frame(width: 824, height: 824)
        .frame(width: 1024, height: 1024)
    }
}

/// A · Cloche: brass serving dome on midnight blue. Fine dining.
struct LogoCloche: View {
    var body: some View {
        IconPlate(fill: AnyShapeStyle(LinearGradient(
            colors: [Color(red: 0.10, green: 0.16, blue: 0.32), Color(red: 0.04, green: 0.06, blue: 0.14)],
            startPoint: .top, endPoint: .bottom))) {
            ClocheShape()
                .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.86, blue: 0.52), Color(red: 0.80, green: 0.56, blue: 0.20)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 8)
                .frame(width: 520, height: 470)
                .offset(y: 20)
            // A small green "live" light on the dome.
            Circle()
                .fill(Color(red: 0.30, green: 0.90, blue: 0.50))
                .frame(width: 54, height: 54)
                .shadow(color: Color(red: 0.30, green: 0.90, blue: 0.50).opacity(0.8), radius: 16)
                .offset(x: 120, y: -40)
        }
    }
}

/// B · Bow tie: a white bow tie on tuxedo black. The head waiter, nothing else.
struct LogoBowTie: View {
    var body: some View {
        IconPlate(fill: AnyShapeStyle(LinearGradient(
            colors: [Color(white: 0.20), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))) {
            BowTieShape()
                .fill(LinearGradient(colors: [.white, Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 10)
                .frame(width: 600, height: 330)
        }
    }
}

/// C · Rack in a bow tie: a server rack dressed as a waiter, on the app's accent blue.
struct LogoRackTie: View {
    let blueTop = Color(red: 0.25, green: 0.56, blue: 1.0)
    let blueBottom = Color(red: 0.07, green: 0.33, blue: 0.86)

    var body: some View {
        IconPlate(fill: AnyShapeStyle(LinearGradient(colors: [blueTop, blueBottom], startPoint: .top, endPoint: .bottom))) {
            ZStack {
                RackShape()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 10)
                RackDetailShape()
                    .fill(blueBottom.opacity(0.85))
            }
            .frame(width: 470, height: 420)
            .offset(y: 70)
            BowTieShape()
                .fill(Color(white: 0.08))
                .overlay(BowTieShape().stroke(.white, lineWidth: 10))
                .frame(width: 300, height: 165)
                .offset(y: -205)
        }
    }
}

// MARK: - Menu bar glyphs (template images: one color, alpha only)

struct GlyphCloche: View { var body: some View { ClocheShape().fill(.foreground).frame(width: 16, height: 14) } }
struct GlyphBowTie: View { var body: some View { BowTieShape().fill(.foreground).frame(width: 18, height: 10) } }
struct GlyphRackTie: View {
    var body: some View {
        VStack(spacing: 1) {
            BowTieShape().fill(.foreground).frame(width: 9, height: 5)
            ZStack {
                RackShape().fill(.foreground)
                RackDetailShape().fill(.white).blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: 15, height: 11)
        }
    }
}

// MARK: - Rendering

extension Snapshots {
    static var logosDirectory: String? { ProcessInfo.processInfo.environment["HW_LOGOS"] }

    static func renderLogos(to dir: String) {
        let concepts: [(String, String, AnyView, AnyView)] = [
            ("a-cloche", "A · Cloche", AnyView(LogoCloche()), AnyView(GlyphCloche())),
            ("b-bowtie", "B · Bow tie", AnyView(LogoBowTie()), AnyView(GlyphBowTie())),
            ("c-racktie", "C · Rack in a bow tie", AnyView(LogoRackTie()), AnyView(GlyphRackTie())),
        ]
        for (slug, _, icon, _) in concepts {
            writeImage(icon, size: 1024, to: "\(dir)/logo-\(slug).png")
        }
        // Comparison sheet: each concept at large and small sizes, on light and dark, plus its menu bar glyph.
        let sheet = VStack(alignment: .leading, spacing: 36) {
            ForEach(concepts, id: \.0) { slug, title, icon, glyph in
                HStack(alignment: .center, spacing: 28) {
                    Text(title).font(.system(size: 22, weight: .semibold)).frame(width: 240, alignment: .leading)
                    scaled(icon, 256)
                    scaled(icon, 64)
                    scaled(icon, 32)
                    scaled(icon, 16)
                    VStack(spacing: 10) {
                        menuBarSample(glyph, dark: false)
                        menuBarSample(glyph, dark: true)
                    }
                }
            }
        }
        .padding(40)
        .background(Color(white: 0.93))
        writeImage(sheet, size: nil, to: "\(dir)/logos-sheet.png")
        print("Logos written to \(dir)")
    }

    /// The 1024 artwork shrunk to an icon size, as the Dock or Finder would show it.
    private static func scaled(_ icon: AnyView, _ size: CGFloat) -> some View {
        icon.scaleEffect(size / 1024).frame(width: size, height: size)
    }

    private static func menuBarSample(_ glyph: AnyView, dark: Bool) -> some View {
        HStack(spacing: 6) {
            glyph
            Text("3").font(.system(size: 13)).foregroundStyle(dark ? .white : .black)
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .foregroundStyle(dark ? .white : .black)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(dark ? Color(white: 0.16) : Color(white: 0.85))
        .scaleEffect(2)
        .frame(width: 120, height: 52)
    }

    static func writeImage<V: View>(_ view: V, size: CGFloat?, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let size { renderer.proposedSize = ProposedViewSize(width: size, height: size) }
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Bow tie, refined (round 2)

/// One wing of the refined tie, in its own rect, knot side on the right (x = 1). Mirror for the
/// other side. Curved top and bottom edges, rounded tips, pinched where it meets the knot.
struct BowWingShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(1.00, 0.36))
        // Top edge sweeps up and out to the tip.
        path.addCurve(to: p(0.12, 0.02), control1: p(0.70, 0.22), control2: p(0.38, 0.00))
        path.addQuadCurve(to: p(0.02, 0.12), control: p(0.02, 0.01))           // rounded top tip
        // Butterfly outer edge: curves in toward the middle, then back out.
        path.addCurve(to: p(0.13, 0.50), control1: p(0.04, 0.26), control2: p(0.14, 0.38))
        path.addCurve(to: p(0.02, 0.88), control1: p(0.14, 0.62), control2: p(0.04, 0.74))
        path.addQuadCurve(to: p(0.12, 0.98), control: p(0.02, 0.99))           // rounded bottom tip
        path.addCurve(to: p(1.00, 0.64), control1: p(0.38, 1.00), control2: p(0.70, 0.78))
        path.addQuadCurve(to: p(1.00, 0.36), control: p(0.95, 0.50))           // pinch at the knot
        path.closeSubpath()
        return path
    }
}

/// Two soft fabric folds radiating from the knot.
struct BowFoldShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(0.93, 0.43))
        path.addQuadCurve(to: p(0.30, 0.24), control: p(0.62, 0.28))
        path.move(to: p(0.93, 0.57))
        path.addQuadCurve(to: p(0.30, 0.76), control: p(0.62, 0.72))
        return path
    }
}

/// The refined tie: two wings, folds, and a separate knot with a thin gap.
struct RefinedBowTie: View {
    var wing: AnyShapeStyle
    var knot: AnyShapeStyle
    var fold: Color
    var gap: Color          // background color, to cut the gap around the knot
    var detailed = true     // folds and shading; off for tiny glyphs

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let knotW = w * 0.14, knotH = h * 0.54
            ZStack {
                HStack(spacing: 0) {
                    wingView.frame(width: (w - knotW) / 2 + knotW * 0.30, height: h)
                    Spacer(minLength: 0)
                    wingView.scaleEffect(x: -1).frame(width: (w - knotW) / 2 + knotW * 0.30, height: h)
                }
                RoundedRectangle(cornerRadius: knotW * 0.42, style: .continuous)
                    .fill(knot)
                    .frame(width: knotW, height: knotH)
                    .background(RoundedRectangle(cornerRadius: knotW * 0.48, style: .continuous)
                        .fill(gap)
                        .frame(width: knotW + w * 0.03, height: knotH + w * 0.03))
            }
        }
    }

    private var wingView: some View {
        ZStack {
            BowWingShape().fill(wing)
            if detailed {
                BowFoldShape().stroke(fold, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .blur(radius: 1.5)
            }
        }
    }
}

struct RefinedTieIcon: View {
    enum Colorway { case classic, inverse, accent }
    let colorway: Colorway

    var body: some View {
        IconPlate(fill: plate) {
            // Soft light from the top, as macOS icons are lit.
            RadialGradient(colors: [.white.opacity(colorway == .inverse ? 0.0 : 0.10), .clear],
                           center: .init(x: 0.5, y: 0.0), startRadius: 0, endRadius: 620)
                .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
            RefinedBowTie(wing: wing, knot: knot, fold: fold, gap: gap)
                .frame(width: 600, height: 300)
                .shadow(color: .black.opacity(colorway == .inverse ? 0.22 : 0.45), radius: 18, y: 14)
                .offset(y: 6)
        }
    }

    private var plate: AnyShapeStyle {
        switch colorway {
        case .classic: AnyShapeStyle(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
        case .inverse: AnyShapeStyle(LinearGradient(colors: [Color(white: 1.0), Color(white: 0.88)], startPoint: .top, endPoint: .bottom))
        case .accent: AnyShapeStyle(LinearGradient(colors: [Color(red: 0.25, green: 0.56, blue: 1.0), Color(red: 0.06, green: 0.30, blue: 0.82)], startPoint: .top, endPoint: .bottom))
        }
    }
    private var wing: AnyShapeStyle {
        switch colorway {
        case .classic, .accent: AnyShapeStyle(LinearGradient(colors: [.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
        case .inverse: AnyShapeStyle(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.04)], startPoint: .top, endPoint: .bottom))
        }
    }
    private var knot: AnyShapeStyle {
        switch colorway {
        case .classic, .accent: AnyShapeStyle(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.80)], startPoint: .top, endPoint: .bottom))
        case .inverse: AnyShapeStyle(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.10)], startPoint: .top, endPoint: .bottom))
        }
    }
    private var fold: Color { colorway == .inverse ? .white.opacity(0.10) : .black.opacity(0.10) }
    private var gap: Color {
        switch colorway {
        case .classic: Color(white: 0.10)
        case .inverse: Color(white: 0.94)
        case .accent: Color(red: 0.15, green: 0.43, blue: 0.91)
        }
    }
}

/// Menu bar glyph for the refined tie: solid silhouette with the knot gap cut out.
struct GlyphRefinedTie: View {
    var body: some View {
        // Wings and knot in the foreground color, with a transparent gap around the knot.
        ZStack {
            ZStack {
                HStack(spacing: 0) {
                    BowWingShape().fill(.foreground).frame(width: 8.4)
                    Spacer(minLength: 0)
                    BowWingShape().fill(.foreground).scaleEffect(x: -1).frame(width: 8.4)
                }
                RoundedRectangle(cornerRadius: 2.0, style: .continuous)
                    .fill(.black)
                    .frame(width: 4.4, height: 7.0)
                    .blendMode(.destinationOut)
                RoundedRectangle(cornerRadius: 1.4, style: .continuous)
                    .fill(.foreground)
                    .frame(width: 2.8, height: 5.4)
            }
            .compositingGroup()
        }
        .frame(width: 19, height: 10)
    }
}

extension Snapshots {
    static func renderRefinedTie(to dir: String) {
        let variants: [(String, String, AnyView)] = [
            ("before", "Before", AnyView(LogoBowTie())),
            ("classic", "B1 · Classic", AnyView(RefinedTieIcon(colorway: .classic))),
            ("inverse", "B2 · Inverse", AnyView(RefinedTieIcon(colorway: .inverse))),
            ("accent", "B3 · Accent blue", AnyView(RefinedTieIcon(colorway: .accent))),
        ]
        for (slug, _, icon) in variants.dropFirst() {
            writeImage(icon, size: 1024, to: "\(dir)/tie-\(slug).png")
        }
        let sheet = VStack(alignment: .leading, spacing: 30) {
            ForEach(variants, id: \.0) { slug, title, icon in
                HStack(alignment: .center, spacing: 26) {
                    Text(title).font(.system(size: 22, weight: .semibold)).frame(width: 190, alignment: .leading)
                    icon.scaleEffect(256 / 1024).frame(width: 256, height: 256)
                    icon.scaleEffect(64 / 1024).frame(width: 64, height: 64)
                    icon.scaleEffect(32 / 1024).frame(width: 32, height: 32)
                    icon.scaleEffect(16 / 1024).frame(width: 16, height: 16)
                    if slug == "classic" {
                        VStack(spacing: 10) {
                            refinedGlyphSample(dark: false)
                            refinedGlyphSample(dark: true)
                        }
                    }
                }
            }
        }
        .padding(40)
        .background(Color(white: 0.93))
        writeImage(sheet, size: nil, to: "\(dir)/tie-sheet.png")
        print("Refined tie written to \(dir)")
    }

    private static func refinedGlyphSample(dark: Bool) -> some View {
        HStack(spacing: 6) {
            GlyphRefinedTie()
            Text("3").font(.system(size: 13))
        }
        .foregroundStyle(dark ? .white : .black)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(dark ? Color(white: 0.16) : Color(white: 0.85))
        .scaleEffect(2)
        .frame(width: 120, height: 52)
    }
}

// MARK: - App icon export

extension Snapshots {
    static var iconsetDirectory: String? { ProcessInfo.processInfo.environment["HW_ICONSET"] }

    /// Writes AppIcon.iconset (every size macOS asks for, rendered from the vector art at that
    /// size, not downscaled). scripts/make-icon.sh turns it into AppIcon.icns.
    static func renderIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let icon = RefinedTieIcon(colorway: .accent)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                let renderer = ImageRenderer(content: icon)
                renderer.scale = CGFloat(pixels) / 1024
                guard let cg = renderer.cgImage else { continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
            }
        }
        print("Iconset written to \(dir)")
    }
}
