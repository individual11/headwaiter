import Foundation

/// Type-to-filter: every word must appear somewhere in an item's texts (names, project,
/// framework, port), ignoring case and accents.
public struct ListFilter: Equatable, Sendable {
    private let words: [String]

    public init(_ text: String) {
        words = text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public var isEmpty: Bool { words.isEmpty }

    public func matches(_ texts: [String]) -> Bool {
        words.allSatisfy { word in
            texts.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

extension Server {
    public var filterTexts: [String] {
        [package.name, project.displayName, framework?.name ?? "", runtime, relativePackagePath]
            + ([primaryPort] + secondaryPorts).map { ":\($0)" }
    }
}

extension ContainerServer {
    public var filterTexts: [String] {
        [name, project?.displayName ?? "", imageShortName, "Docker"]
            + ([primaryPort] + secondaryPorts).map { ":\($0)" }
    }
}

/// Moving a selection through a list of row IDs.
public enum ListSelection {
    /// One row up or down, stopping at the ends. With nothing selected, down starts at the top
    /// and up at the bottom.
    public static func move(_ selection: String?, by step: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let selection, let i = ids.firstIndex(of: selection) else { return step > 0 ? ids.first : ids.last }
        return ids[min(max(i + step, 0), ids.count - 1)]
    }

    /// The selection after the list changed: the same row if it's still there, else the row that
    /// took its place.
    public static func keep(_ selection: String?, from old: [String], to new: [String]) -> String? {
        guard let selection, !new.contains(selection) else { return selection }
        guard let i = old.firstIndex(of: selection), !new.isEmpty else { return nil }
        // The nearest following row that survived, else the nearest preceding one.
        return old[i...].first(where: new.contains) ?? old[..<i].last(where: new.contains)
    }
}
