// Draws the DMG window's background (run by make-dmg-layout.sh).
// Usage: dmg-background <app icon png> <output folder>
// Writes background.png, background@2x.png and mockup.png (a preview with the icons in place).
import AppKit
import SwiftUI

// Keep in step with make-dmg-layout.sh. The picture is taller than the window, so a taller or
// shorter title bar never leaves a gap at the bottom.
let width: CGFloat = 700, windowHeight: CGFloat = 440, height: CGFloat = 500
let iconSize: CGFloat = 128, iconY: CGFloat = 160, leftX: CGFloat = 170, rightX: CGFloat = 530

func rgb(_ h: UInt32) -> Color {
    Color(red: Double(h >> 16 & 255) / 255, green: Double(h >> 8 & 255) / 255, blue: Double(h & 255) / 255)
}

struct Bow: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        for side in [-1.0, 1.0] as [CGFloat] {
            func sx(_ x: CGFloat) -> CGFloat { 0.5 + side * (0.5 - x) }
            path.move(to: p(sx(0.43), 0.36))
            path.addQuadCurve(to: p(sx(0.05), 0.04), control: p(sx(0.2), 0.04))
            path.addQuadCurve(to: p(sx(0), 0.14), control: p(sx(0), 0.04))
            path.addQuadCurve(to: p(sx(0), 0.86), control: p(sx(0.1), 0.5))
            path.addQuadCurve(to: p(sx(0.05), 0.96), control: p(sx(0), 0.96))
            path.addQuadCurve(to: p(sx(0.43), 0.64), control: p(sx(0.2), 0.96))
            path.closeSubpath()
        }
        path.addRoundedRect(in: CGRect(x: r.minX + 0.44 * r.width, y: r.minY + 0.26 * r.height,
                                       width: 0.12 * r.width, height: 0.48 * r.height),
                            cornerSize: CGSize(width: 0.04 * r.width, height: 0.04 * r.width))
        return path
    }
}

/// A folded card standing on the table.
struct Card: View {
    let gold = rgb(0xC9A557)
    var body: some View {
        ZStack {
            Ellipse().fill(.black.opacity(0.35)).frame(width: 330, height: 18).blur(radius: 8).offset(y: 56)
            Path { p in
                p.move(to: CGPoint(x: 14, y: 0)); p.addLine(to: CGPoint(x: 286, y: 0))
                p.addLine(to: CGPoint(x: 296, y: 12)); p.addLine(to: CGPoint(x: 4, y: 12)); p.closeSubpath()
            }
            .fill(rgb(0xCFD7E4)).frame(width: 300, height: 122)
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [.white, rgb(0xF1F3F8)], startPoint: .top, endPoint: .bottom))
                .frame(width: 300, height: 110).offset(y: 2)
            RoundedRectangle(cornerRadius: 2).strokeBorder(gold, lineWidth: 1).frame(width: 286, height: 96).offset(y: 2)
            VStack(spacing: 1) {
                Bow().fill(gold).frame(width: 30, height: 17).padding(.bottom, 3)
                Text("Your server")
                Text("will be right with you")
            }
            .font(.custom("Snell Roundhand", size: 25).bold())
            .foregroundStyle(rgb(0x16264A))
            .offset(y: 1)
        }
    }
}

struct Background: View {
    var body: some View {
        ZStack {
            // Light throughout where Finder draws the icon names: it uses black text over a picture.
            LinearGradient(colors: [rgb(0xFBFCFE), rgb(0xDDE7F7)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(colors: [rgb(0x2E76EE), rgb(0x1450CF)], startPoint: .top, endPoint: .bottom)
                    .frame(height: height - 340)
                    .padding(.horizontal, -40)   // wider, so its shadow doesn't fade at the edges
                    .shadow(color: .black.opacity(0.18), radius: 8, y: -3)
            }
            HStack(spacing: 7) {
                ForEach(0..<7, id: \.self) { i in
                    Circle().fill(rgb(0x1F63E0).opacity(0.25 + Double(i) * 0.11)).frame(width: 5, height: 5)
                }
                Image(systemName: "chevron.right").font(.system(size: 24, weight: .bold)).foregroundStyle(rgb(0x1F63E0))
            }
            .position(x: width / 2, y: iconY)
            Card().position(x: width / 2, y: 340)
        }
        .frame(width: width, height: height)
        .clipped()
        .environment(\.colorScheme, .light)
    }
}

struct Mockup: View {
    let icon: NSImage
    func item(_ image: NSImage, _ name: String, _ x: CGFloat) -> some View {
        ZStack {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: iconSize, height: iconSize).position(x: x, y: iconY)
            Text(name).font(.system(size: 13)).foregroundStyle(.black).position(x: x, y: iconY + 78)
        }
    }
    var body: some View {
        let apps = NSWorkspace.shared.icon(forFile: "/Applications")
        ZStack {
            Background()
            item(icon, "Headwaiter", leftX)
            item({ apps.size = NSSize(width: 512, height: 512); return apps }(), "Applications", rightX)
        }
        .frame(width: width, height: windowHeight, alignment: .top).clipped()
    }
}

@MainActor func write<V: View>(_ view: V, scale: CGFloat, to path: String) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
    rep.size = NSSize(width: Double(rep.pixelsWide) / scale, height: Double(rep.pixelsHigh) / scale)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

try MainActor.assumeIsolated {
    let args = CommandLine.arguments
    guard args.count == 3, let icon = NSImage(contentsOfFile: args[1]) else {
        print("usage: dmg-background <app icon png> <output folder>"); exit(1)
    }
    try write(Background(), scale: 1, to: args[2] + "/background.png")
    try write(Background(), scale: 2, to: args[2] + "/background@2x.png")
    try write(Mockup(icon: icon), scale: 2, to: args[2] + "/mockup.png")
}
