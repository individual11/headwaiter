import AppKit
import HeadwaiterCore
import SwiftUI

/// Framework identity: a color and a one- or two-letter mark shown on each row's tile.
/// Original marks (letters on color), not the frameworks' logos.
enum FrameworkStyle {
    static func color(_ s: Server) -> Color { color(id: s.framework?.id, runtime: s.runtime) }
    static func mark(_ s: Server) -> String { mark(id: s.framework?.id, runtime: s.runtime) }
    static func markText(_ s: Server) -> Color { markText(id: s.framework?.id) }

    static func color(id: String?, runtime: String) -> Color {
        switch id {
        case "next": return adaptive(light: NSColor(white: 0.12, alpha: 1), dark: NSColor(white: 0.92, alpha: 1))
        case "vite": return Color(red: 0.49, green: 0.36, blue: 0.96)
        case "express": return Color(red: 0.42, green: 0.45, blue: 0.50)
        case "fastapi": return Color(red: 0.0, green: 0.59, blue: 0.53)
        case "django": return Color(red: 0.05, green: 0.40, blue: 0.27)
        case "flask", "uvicorn": return Color(red: 0.25, green: 0.42, blue: 0.62)
        case "astro": return Color(red: 0.98, green: 0.42, blue: 0.16)
        case "remix", "react-router": return Color(red: 0.24, green: 0.33, blue: 0.85)
        case "nest": return Color(red: 0.88, green: 0.13, blue: 0.29)
        case "storybook": return Color(red: 1.0, green: 0.28, blue: 0.52)
        case "jupyter": return Color(red: 0.95, green: 0.49, blue: 0.13)
        case "expo": return adaptive(light: NSColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 1),
                                     dark: NSColor(red: 0.80, green: 0.82, blue: 0.86, alpha: 1))
        case "hono", "fastify", "koa": return Color(red: 0.86, green: 0.36, blue: 0.20)
        case "gin", "echo", "fiber", "chi", "gorilla": return Color(red: 0.0, green: 0.62, blue: 0.78)
        case "hugo": return Color(red: 0.93, green: 0.25, blue: 0.47)
        case "rails": return Color(red: 0.80, green: 0.12, blue: 0.12)
        case "sinatra", "hanami", "puma", "rack": return Color(red: 0.70, green: 0.22, blue: 0.22)
        case "jekyll": return Color(red: 0.80, green: 0.10, blue: 0.20)
        default:
            switch runtime {
            case "python": return Color(red: 0.22, green: 0.46, blue: 0.69)
            case "go": return Color(red: 0.0, green: 0.62, blue: 0.78)
            case "ruby": return Color(red: 0.70, green: 0.22, blue: 0.22)
            default: return Color(red: 0.36, green: 0.58, blue: 0.27)
            }
        }
    }

    /// Near-black brand colors vanish in dark mode; flip them to near-white there.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    /// Text color on a mark tile: dark text on light tiles (Next.js in dark mode), else white.
    static func markText(id: String?) -> Color {
        ["next", "expo"].contains(id) ? adaptive(light: .white, dark: .black) : .white
    }

    static func mark(id: String?, runtime: String) -> String {
        switch id {
        case "next": return "N"
        case "vite": return "V"
        case "express": return "Ex"
        case "fastapi": return "Fa"
        case "django": return "Dj"
        case "flask": return "Fl"
        case "uvicorn": return "Uv"
        case "astro": return "A"
        case "remix": return "R"
        case "react-router": return "RR"
        case "nest": return "Ne"
        case "storybook": return "S"
        case "jupyter": return "Ju"
        case "expo": return "Xo"
        case "hono": return "H"
        case "fastify": return "F"
        case "koa": return "K"
        case "gin": return "Gi"
        case "echo": return "Ec"
        case "fiber": return "Fb"
        case "chi": return "Ch"
        case "gorilla": return "Gm"
        case "hugo": return "Hu"
        case "rails": return "Ra"
        case "sinatra": return "Si"
        case "hanami": return "Ha"
        case "jekyll": return "Je"
        case "puma": return "Pu"
        case "rack": return "Rk"
        default:
            switch runtime {
            case "python": return "Py"
            case "bun": return "Bn"
            case "deno": return "De"
            case "go": return "Go"
            case "ruby": return "Rb"
            default: return "JS"
            }
        }
    }

    static func name(_ s: Server) -> String { s.framework?.name ?? s.runtime }
}
