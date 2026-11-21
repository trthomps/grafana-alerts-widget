import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: AlertStore
    let actions: AppActions
    @AppStorage(PrefKey.showHidden) private var showHidden = false
    @AppStorage(PrefKey.iconColor) private var iconColor: IconColor = .color
    @AppStorage(PrefKey.countMode) private var countMode: CountMode = .rules
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            content
            if let message = store.silenceMessage {
                Divider()
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 420)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            GrafanaMarkView(monochrome: iconColor == .monochrome)
                .frame(width: 16, height: 16)
            Text("Alerts")
                .font(.system(size: 13, weight: .semibold))
            if store.badgeCount > 0 {
                Text("\(store.badgeCount) firing")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(iconColor == .monochrome ? Color.secondary
                        : Prefs.severityColors ? (store.worstSeverity ?? .critical).color : .red))
                    .help(countMode == .instances ? "Firing alert instances" : "Firing alert rules")
            }
            if store.pendingCount > 0 {
                Text("\(store.pendingCount) pending")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().strokeBorder(Color.orange.opacity(0.6)))
            }
            Spacer()
            IconButton(systemName: "arrow.clockwise", help: "Refresh now", busy: store.isRefreshing) {
                actions.refresh()
            }
            IconButton(systemName: "gearshape", help: "Settings") {
                actions.openSettings()
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if store.rules.isEmpty && store.lastFetched == nil {
            StatusMessage(error: store.error, retry: actions.refresh, openSettings: actions.openSettings)
                .padding(16)
        } else if store.shown.isEmpty && (!showHidden || store.hidden.isEmpty) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 26))
                    .foregroundStyle(.green)
                Text("Nothing firing")
                    .font(.system(size: 13, weight: .semibold))
                if !store.hidden.isEmpty {
                    Text("\(store.hidden.count) hidden by your filters")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                if let error = store.error {
                    ErrorLine(text: "\(error.title). \(error.message)").padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = store.error {
                        ErrorLine(text: "\(error.title). \(error.message)")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        Divider()
                    } else if let warning = store.silenceWarning {
                        ErrorLine(text: warning)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        Divider()
                    }
                    ForEach(store.shown) { item in
                        rows(for: item, dimmed: false)
                    }
                    if showHidden && !store.hidden.isEmpty {
                        HStack {
                            Text("Hidden by filters")
                                .font(.system(size: 10.5, weight: .semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        ForEach(store.hidden) { item in
                            rows(for: item, dimmed: true)
                        }
                    }
                }
            }
            .frame(height: listHeight)
        }
    }

    @ViewBuilder
    private func rows(for item: RuleItem, dimmed: Bool) -> some View {
        let isExpanded = expanded.contains(item.id)
        RuleRow(item: item, now: store.now, expanded: isExpanded,
                toggle: { toggle(item.id) },
                open: { open(item.rule.uid) })
            .opacity(dimmed ? 0.6 : 1)
            .contextMenu { RuleMenu(store: store, rule: item.rule, instance: nil, close: actions.closePopover) }
        if isExpanded {
            let common = item.rule.commonLabels
            ForEach(item.instances) { instance in
                InstanceRow(instance: instance, common: common, now: store.now)
                    .opacity(dimmed ? 0.6 : 1)
                    .contextMenu { RuleMenu(store: store, rule: item.rule, instance: instance, close: actions.closePopover) }
            }
            if item.hiddenInstances > 0 {
                Text("\(item.hiddenInstances) more hidden by filters")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 42)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Divider().padding(.leading, 42)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private var listHeight: CGFloat {
        var height: CGFloat = store.error == nil && store.silenceWarning == nil ? 0 : 44
        let items = store.shown + (showHidden ? store.hidden : [])
        if showHidden && !store.hidden.isEmpty { height += 30 }
        for item in items {
            height += 78
            if expanded.contains(item.id) {
                height += CGFloat(item.instances.count) * 52 + (item.hiddenInstances > 0 ? 20 : 0)
            }
        }
        return min(max(height, 60), 540)
    }

    private func open(_ uid: String) {
        store.open(ruleUID: uid)
        actions.closePopover()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if !store.hidden.isEmpty {
                Button {
                    showHidden.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showHidden ? "eye.slash" : "line.3.horizontal.decrease.circle")
                        Text(showHidden ? "Hide filtered" : "\(store.hidden.count) filtered")
                    }
                }
                .buttonStyle(.borderless)
                .help("Alerts your filters hide. They don't count toward the badge.")
            } else if let fetched = store.lastFetched {
                Text("Updated \(Fmt.ago(fetched, now: store.now))")
            }
            Spacer()
            Button("Open Grafana") { actions.openWeb(); actions.closePopover() }
                .buttonStyle(.borderless)
            Button("Quit") { actions.quit() }
                .buttonStyle(.borderless)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Rows

struct RuleRow: View {
    let item: RuleItem
    let now: Date
    let expanded: Bool
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovering = false

    private var rule: AlertRule { item.rule }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StateIcon(state: item.state, severity: item.severity, silenced: item.allSilenced)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(rule.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(item.state.isActive && !item.allSilenced ? .primary : .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let since = item.since {
                        Text(Fmt.ago(since, now: now, short: true))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help("Active since \(since.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                if let summary = item.summary {
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 5) {
                    Text("\(rule.folder) › \(rule.group)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.instances.count > 1 || item.hiddenInstances > 0 {
                        Button(action: toggle) {
                            HStack(spacing: 2) {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                Text("\(item.instances.count) instance\(item.instances.count == 1 ? "" : "s")")
                            }
                        }
                        .buttonStyle(.borderless)
                        .help(expanded ? "Hide instances" : "Show instances")
                    } else if item.instances.count == 1 {
                        Button(action: toggle) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .help(expanded ? "Hide details" : "Show labels")
                    }
                    Spacer(minLength: 4)
                    if item.allSilenced { Chip(text: "silenced", tint: .secondary) }
                    if item.state == .pending { Chip(text: "pending", tint: .orange) }
                    if item.state == .recovering { Chip(text: "recovering", tint: .green) }
                    if let reason = item.instances.first(where: { $0.reason != nil })?.reason {
                        Chip(text: reason, tint: .purple)
                    }
                    if let severity = item.instances.first?.labels["severity"] ?? rule.labels["severity"] {
                        Chip(text: severity, tint: item.severity == .unknown ? .secondary : item.severity.color)
                    }
                    if let reason = item.hiddenReason { Chip(text: reason, tint: .secondary) }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help("Open in Grafana. Right-click to silence.")
    }
}

struct InstanceRow: View {
    let instance: AlertInstance
    let common: [String: String]
    let now: Date
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(instance.silenced ? Color.secondary : instance.state == .pending ? .orange : instance.severity.color)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                if let summary = instance.summary {
                    Text(summary)
                        .font(.system(size: 11.5))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let labels = instance.distinguishingLabels(common: common)
                if !labels.isEmpty {
                    Text(labels.map { "\($0.0)=\($0.1)" }.joined(separator: "  "))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let activeAt = instance.activeAt {
                    Text(Fmt.ago(activeAt, now: now, short: true)).monospacedDigit()
                }
                if instance.silenced { Text("silenced") }
                else if instance.state != .firing { Text(instance.state.title.lowercased()) }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 42)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hovering = $0 }
        .help(instance.value.map { "Value: \($0)" } ?? "")
    }
}

/// Right-click menu for a rule or one of its instances.
struct RuleMenu: View {
    let store: AlertStore
    let rule: AlertRule
    let instance: AlertInstance?
    let close: () -> Void

    private static let durations: [(String, TimeInterval)] = [
        ("1 hour", 3600), ("4 hours", 4 * 3600), ("1 day", 86400), ("1 week", 7 * 86400),
    ]

    var body: some View {
        Button("Open in Grafana") { store.open(ruleUID: rule.uid); close() }
        if let url = rule.runbookURL ?? instance?.annotations["runbook_url"].nonEmpty.flatMap(URL.init(string:)) {
            Button("Open Runbook") { NSWorkspace.shared.open(url); close() }
        }
        if let url = store.dashboardURL(rule) {
            Button("Open Dashboard Panel") { NSWorkspace.shared.open(url); close() }
        }
        Divider()
        Menu(instance == nil ? "Silence Rule" : "Silence This Instance") {
            ForEach(Self.durations, id: \.0) { title, duration in
                Button("For \(title)") {
                    Task { await store.silence(rule: rule, instance: instance, duration: duration) }
                }
            }
        }
        if instance != nil {
            Menu("Silence Whole Rule") {
                ForEach(Self.durations, id: \.0) { title, duration in
                    Button("For \(title)") {
                        Task { await store.silence(rule: rule, instance: nil, duration: duration) }
                    }
                }
            }
        }
        Divider()
        Button("Hide This Rule") { Prefs.append(rule.uid, to: PrefKey.hiddenRuleUIDs) }
        Button("Hide Folder “\(rule.folder)”") { Prefs.append(Glob.literal(rule.folder), to: PrefKey.excludeFolders) }
        Button("Hide Group “\(rule.group)”") {
            Prefs.append(Glob.literal("\(rule.folder)/\(rule.group)"), to: PrefKey.excludeGroups)
        }
        Divider()
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rule.name, forType: .string)
        }
        if let instance {
            Button("Copy Labels") {
                let text = instance.labels.filter { !$0.key.hasPrefix("__") }.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

// MARK: - Bits

struct StateIcon: View {
    let state: AlertState
    let severity: Severity
    var silenced = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
    }

    private var symbol: String {
        if silenced { return "bell.slash" }
        switch state {
        case .firing: return "exclamationmark.circle"
        case .recovering: return "arrow.up.circle"
        case .pending: return "circle.dotted"
        case .normal: return "checkmark.circle"
        }
    }

    private var tint: Color {
        if silenced { return .secondary }
        switch state {
        case .firing: return severity == .unknown ? .red : severity.color
        case .recovering: return .green
        case .pending: return .orange
        case .normal: return .green
        }
    }
}

struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.13)))
    }
}

struct ErrorLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct StatusMessage: View {
    let error: GrafanaError?
    let retry: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let error {
                Image(systemName: error.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text(error.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(error.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Settings…", action: openSettings)
                    Button("Try Again", action: retry)
                }
                .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
                Text("Loading alerts…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.65)
                } else {
                    Image(systemName: systemName).font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(busy)
    }
}

enum Fmt {
    static func ago(_ date: Date, now: Date, short: Bool = false) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return short ? "now" : "just now" }
        let minutes = Int(seconds / 60)
        let value: String
        if minutes < 60 { value = "\(minutes)m" }
        else if minutes < 60 * 24 { value = "\(minutes / 60)h" }
        else if minutes < 60 * 24 * 30 { value = "\(minutes / 1440)d" }
        else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
        return short ? value : "\(value) ago"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        if hours >= 24 * 7, hours % (24 * 7) == 0 { return "\(hours / (24 * 7)) week\(hours == 168 ? "" : "s")" }
        if hours >= 24, hours % 24 == 0 { return "\(hours / 24) day\(hours == 24 ? "" : "s")" }
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }
}
