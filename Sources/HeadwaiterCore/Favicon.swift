import CryptoKit
import Foundation

/// Finds a project's own icon (its favicon) to show on its rows instead of the framework mark.
///
/// Project files come first: they need no network request and don't add lines to the server's
/// log. Asking the running server for `/favicon.ico` is the app's fallback (see `FaviconStore`).
/// Starter icons that frameworks ship in new projects are recognized and skipped, so only icons
/// someone actually chose replace the framework mark.
public enum Favicon {
    /// Where frameworks keep the icon, relative to a package or project folder, best first:
    /// vector and PNG before ICO, framework conventions before generic names.
    public static let candidates = [
        // Next.js App Router (file conventions)
        "app/icon.svg", "app/icon.png", "app/favicon.ico",
        "src/app/icon.svg", "src/app/icon.png", "src/app/favicon.ico",
        // Vite, Create React App, Astro, Nuxt, Rails, Next.js Pages Router
        "public/favicon.svg", "public/icon.svg", "public/favicon.png", "public/icon.png",
        "public/favicon.ico", "public/apple-touch-icon.png",
        // SvelteKit, Hugo, Flask, Django (project-level static)
        "static/favicon.svg", "static/favicon.png", "static/favicon.ico",
        "src/lib/assets/favicon.svg", "src/favicon.svg", "src/favicon.ico",
        // Jekyll and plain sites
        "favicon.svg", "favicon.png", "favicon.ico",
    ]

    /// Largest icon worth loading; real favicons are a few KB.
    public static let maxBytes = 1_000_000

    /// SHA-256 of the starter icons in official project templates (checked 2026-11-22):
    /// Next.js (create-next-app), Create React App, Astro (svg and ico), Nuxt, create-vue,
    /// Rails (icon.png, icon.svg).
    public static let starterHashes: Set<String> = [
        "c28fdd2a4f31e2dc64f653962286da5c82a4cdfc518b242d32812c624e9a19a4", // Next.js favicon.ico
        "3d10f7da6c603178340081668c4ac5b3ae9743ca9a262ab0fcd312fbb9f48bdd", // Create React App favicon.ico
        "2d7a310283d6f9cc753210d83224cd6db6348cb82a5536348884e5831d46203f", // Astro favicon.svg
        "09d2ac08d8cca9b6e1f90221f345a8c4dd0371c64a0dc52b6f96fc589b1e3d67", // Astro favicon.ico
        "1057b17aec08a7191d134000203947f195a8aa7c84c39f1164cee8d01279762a", // Nuxt favicon.ico
        "db74ab0b78338c1f778f8398c45f4103c99aea0e845a3118a7750b4eeafd3445", // create-vue favicon.ico
        "2e29c62b03e514c5a15f289f8fdc0abca6e22d0e91970503c9e2b7e0552c911c", // Rails icon.png
        "601dfb4db252852f3880ffc355bce0d4507b01afca6879189d10a65470ae6e3a", // Rails icon.svg
    ]

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True for a starter icon from a framework template.
    public static func isStarter(_ data: Data) -> Bool { starterHashes.contains(sha256(data)) }

    /// Worth showing: not empty (Rails ships a 0-byte favicon.ico), not huge, not a starter icon.
    public static func isUsable(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= maxBytes && !isStarter(data)
    }

    /// Folders to search for one server: its package, then the project root if different.
    public static func searchFolders(packagePath: String, projectRoot: String) -> [String] {
        packagePath == projectRoot ? [packagePath] : [packagePath, projectRoot]
    }

    /// The first usable icon in `folders`, checking candidates in order.
    /// `load` reads a file's bytes (nil if unreadable); `fs` decides what exists, so protected
    /// folders stay untouched while `ProtectedFolderGate` is in effect.
    public static func find(in folders: [String], fs: FileReading,
                            load: (String) -> Data? = { FileManager.default.contents(atPath: $0) })
        -> (path: String, data: Data)? {
        for folder in folders where !fs.isAccessDenied(folder) {
            for candidate in candidates {
                let path = (folder as NSString).appendingPathComponent(candidate)
                guard fs.exists(path), let data = load(path), isUsable(data) else { continue }
                return (path, data)
            }
        }
        return nil
    }

    /// `http://localhost:<port>/favicon.ico` for a server URL; the only path ever requested,
    /// because loading the page itself can make dev servers compile it.
    public static func serverURL(for url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/favicon.ico"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }
}
