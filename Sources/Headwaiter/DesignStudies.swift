import AppKit
import HeadwaiterCore
import SwiftUI

// Three static design explorations of the popover, rendered with `HW_STUDIES=<dir>`.
// Same sample data and states for each, so they can be compared side by side. Not wired
// into the app; the chosen direction gets built into PopoverView.

struct StudyState {
    var groups: [ProjectGroup]
    var hovered: Server.ID?
    var new: Set<Server.ID>
    var stopping: Server.ID?
    var serverCount: Int { groups.reduce(0) { $0 + $1.servers.count } }
}

// MARK: - A. Native, refined

struct StudyNative: View {
    let state: StudyState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.gradient))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(state.serverCount) servers running").font(.system(size: 13, weight: .semibold))
                    Text("across \(state.groups.count) projects").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            VStack(spacing: 8) {
                ForEach(state.groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(group.project.name).font(.system(size: 11, weight: .semibold))
                            if let tree = group.project.worktree {
                                Label(tree, systemImage: "arrow.triangle.branch")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                            }
                            Spacer(minLength: 8)
                            Text(Display.abbreviatingHome(group.project.rootPath))
                                .font(.system(size: 10))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                        ForEach(group.servers) { s in
                            nativeRow(s)
                        }
                    }
                    .padding(.bottom, 4)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
                }
            }
            .padding(.horizontal, 10)

            HStack(spacing: 6) {
                Image(systemName: "lightbulb").font(.system(size: 10))
                Text("Option-click a server to copy its URL")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .frame(width: 400)
    }

    func nativeRow(_ s: Server) -> some View {
        let hovered = state.hovered == s.id
        let stopping = state.stopping == s.id
        return HStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                Text(FrameworkStyle.mark(s))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(FrameworkStyle.markText(s))
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(FrameworkStyle.color(s).gradient))
                if state.new.contains(s.id) {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: -3, y: -3)
                }
            }
            .opacity(stopping ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(s.package.name).font(.system(size: 13, weight: .medium))
                    Text(FrameworkStyle.name(s)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(stopping ? "Stopping…" : s.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .foregroundStyle(stopping ? .secondary : .primary)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 3) {
                    Text(verbatim: ":\(s.primaryPort)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                    if hovered { Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tint) }
                }
                Text(Display.uptime(since: s.startTime)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            ZStack {
                if stopping { ProgressView().controlSize(.mini) }
                else if hovered { Image(systemName: "stop.circle").font(.system(size: 15)).foregroundStyle(.secondary) }
            }
            .frame(width: 18)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered ? Color.accentColor.opacity(0.12) : .clear))
        .padding(.horizontal, 3)
    }
}

// MARK: - B. Developer-tool flavor

struct StudyDevTool: View {
    let state: StudyState
    let mono = Font.system(size: 11.5, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(.green).frame(width: 7, height: 7).shadow(color: .green.opacity(0.6), radius: 3)
                Text("\(state.serverCount) running").font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text("· \(state.groups.count) projects").font(mono).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            ForEach(state.groups) { group in
                HStack(spacing: 6) {
                    Text(Display.abbreviatingHome(group.project.rootPath))
                        .lineLimit(1).truncationMode(.head)
                    if let tree = group.project.worktree {
                        Text("[\(tree)]").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 3)

                ForEach(group.servers) { s in devRow(s) }
            }

            Divider().padding(.top, 8)
            HStack {
                Text("⌥-click copies URL").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text("libproc · 2s").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 400)
    }

    func devRow(_ s: Server) -> some View {
        let hovered = state.hovered == s.id
        let stopping = state.stopping == s.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle()
                    .fill(stopping ? Color.yellow : Color.green)
                    .frame(width: 6, height: 6)
                Text(s.package.name).font(.system(size: 12.5, weight: .semibold))
                if state.new.contains(s.id) {
                    Text("new").font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 3)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.blue.opacity(0.6)))
                }
                Text(FrameworkStyle.name(s).lowercased()).font(mono).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(verbatim: "localhost:\(s.primaryPort)")
                    .font(mono)
                    .foregroundStyle(.blue)
                    .underline(hovered)
                Text(Display.uptime(since: s.startTime).replacingOccurrences(of: " ", with: ""))
                    .font(mono).foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
            HStack(spacing: 4) {
                Text("$").foregroundStyle(.green.opacity(0.8))
                Text(stopping ? "kill -TERM \(s.rootPID)" : Display.command(s.root))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if hovered { Text("[stop]").foregroundStyle(.red) }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.leading, 13)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(hovered ? Color.primary.opacity(0.06) : .clear)
        .opacity(stopping ? 0.6 : 1)
    }
}

// MARK: - C. Bold and colorful

struct StudyBold: View {
    let state: StudyState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(state.serverCount)")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                VStack(alignment: .leading, spacing: 0) {
                    Text("servers running").font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("\(state.groups.count) projects").font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "gearshape.fill").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ForEach(state.groups) { group in
                HStack(spacing: 6) {
                    Text(group.project.name.uppercased())
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .kerning(0.8)
                    if let tree = group.project.worktree {
                        Text(tree)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.orange.gradient))
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)

                ForEach(group.servers) { s in boldRow(s) }
            }
            .padding(.bottom, 2)

            Text("✨ Option-click any server to copy its URL")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .frame(width: 400)
    }

    func boldRow(_ s: Server) -> some View {
        let color = FrameworkStyle.color(s)
        let hovered = state.hovered == s.id
        let stopping = state.stopping == s.id
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color.gradient).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.package.name).font(.system(size: 15, weight: .bold, design: .rounded))
                    if state.new.contains(s.id) {
                        Text("NEW").font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.pink.gradient))
                    }
                }
                Text(FrameworkStyle.name(s).uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .kerning(0.6)
                    .foregroundStyle(color)
                    .brightness(0.08)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: ":\(s.primaryPort)")
                    .font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                Text(stopping ? "stopping…" : Display.uptime(since: s.startTime))
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            ZStack {
                if stopping { ProgressView().controlSize(.mini) }
                else if hovered {
                    Image(systemName: "stop.circle.fill").font(.system(size: 18)).foregroundStyle(color)
                }
            }
            .frame(width: 22)
        }
        .padding(.vertical, 7)
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(hovered ? 0.16 : 0.0)))
        .opacity(stopping ? 0.55 : 1)
        .padding(.horizontal, 6)
    }
}

// MARK: - Rendering

extension Snapshots {
    static var studiesDirectory: String? { ProcessInfo.processInfo.environment["HW_STUDIES"] }

    static func renderStudies(to dir: String) {
        let now = Date().timeIntervalSince1970
        let servers = sampleServers(now: now).filter { !$0.package.accessDenied && $0.package.name != "stubborn" }
        let id = { (name: String) in servers.first { $0.package.name == name }?.id }
        let state = StudyState(
            groups: ServerStore.group(servers),
            hovered: id("@shop/api"),
            new: Set([servers.first { $0.project.worktree != nil }?.id].compactMap { $0 }),
            stopping: id("docs"))

        let studies: [(String, AnyView)] = [
            ("a-native", AnyView(StudyNative(state: state))),
            ("b-devtool", AnyView(StudyDevTool(state: state))),
            ("c-bold", AnyView(StudyBold(state: state))),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            for (name, view) in studies {
                write(view, scheme: scheme, to: "\(dir)/study-\(name)-\(suffix).png")
            }
            write(HStack(alignment: .top, spacing: 24) {
                ForEach(studies, id: \.0) { name, view in
                    VStack(spacing: 8) {
                        Text(label(name)).font(.system(size: 15, weight: .semibold))
                        view
                            .background(Color(nsColor: .windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                    }
                }
            }
            .padding(28)
            .background(scheme == .light ? Color(white: 0.86) : Color(white: 0.1)),
                  scheme: scheme, to: "\(dir)/studies-side-by-side-\(suffix).png")
        }
        print("Studies written to \(dir)")
    }

    private static func label(_ name: String) -> String {
        switch name {
        case "a-native": "A · Native, refined"
        case "b-devtool": "B · Developer tool"
        default: "C · Bold and colorful"
        }
    }
}
