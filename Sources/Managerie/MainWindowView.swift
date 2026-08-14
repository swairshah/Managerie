import SwiftUI
import AppKit

// MARK: - Window Theme (motion from clearly, chrome from replay)

enum WindowTheme {
    enum Motion {
        /// Quick feedback: button hovers, toggle states
        static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.85)
        /// Primary transitions: pane switches, panel show/hide
        static let smooth = Animation.spring(response: 0.35, dampingFraction: 0.75)
        /// Hover backgrounds — instant-feeling
        static let hover = Animation.easeOut(duration: 0.15)
    }
}

// MARK: - Sidebar material (real translucent macOS sidebar)

struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Panes

enum MainPane: String, CaseIterable, Identifiable {
    case sessions
    case settings
    case integrations
    case history
    case permissions
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: return "Sessions"
        case .settings: return "Settings"
        case .integrations: return "Integrations"
        case .history: return "History"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .sessions: return "square.stack.3d.up"
        case .settings: return "gearshape"
        case .integrations: return "puzzlepiece.extension"
        case .history: return "clock"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Main Window

struct MainWindowView: View {
    @StateObject private var monitor = VoiceMonitor()
    @AppStorage("mainWindowPane") private var paneRaw = MainPane.sessions.rawValue

    private var pane: MainPane {
        MainPane(rawValue: paneRaw) ?? .sessions
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 192)
                .background(SidebarMaterial().ignoresSafeArea())

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
                .ignoresSafeArea()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor).ignoresSafeArea())
        }
        .ignoresSafeArea()
        .frame(minWidth: 780, minHeight: 560)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Identity — same glyph as the menubar dropdown, below the traffic lights
            HStack(spacing: 9) {
                Image("MenuBarIconOff", bundle: .module)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 22)
                    .foregroundStyle(.primary)
                Text("Managerie")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 46)
            .padding(.bottom, 16)

            ForEach(MainPane.allCases) { item in
                SidebarItem(
                    label: item.label,
                    icon: item.icon,
                    isActive: pane == item,
                    badge: item == .sessions ? sessionBadge : nil
                ) {
                    withAnimation(WindowTheme.Motion.smooth) {
                        paneRaw = item.rawValue
                    }
                }
            }

            Spacer()

            // Footer: version + broker state, quiet
            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.serverEnabled && monitor.serverOnline ? Color.primary.opacity(0.45) : Color.primary.opacity(0.15))
                    .frame(width: 6, height: 6)
                Text(monitor.serverEnabled && monitor.serverOnline ? "Listening" : "Paused")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("v\(appVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 6)
        .onAppear { monitor.start() }
    }

    private var sessionBadge: String? {
        monitor.sessions.isEmpty ? nil : "\(monitor.sessions.count)"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .sessions: SessionsTabView(monitor: monitor)
        case .settings: SettingsTabView()
        case .integrations: IntegrationsTabView()
        case .history: HistoryView()
        case .permissions: PermissionsView()
        case .about: AboutView()
        }
    }
}

// MARK: - Sidebar Item (clearly-style hover/active)

private struct SidebarItem: View {
    let label: String
    let icon: String
    let isActive: Bool
    var badge: String? = nil
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)

                Text(label)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? .primary : (isHovering ? .primary : .secondary))

                Spacer()

                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive
                        ? Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12)
                        : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(WindowTheme.Motion.hover) {
                isHovering = hovering
            }
        }
    }
}
