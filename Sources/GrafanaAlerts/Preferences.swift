import AppKit
import SwiftUI

enum IconColor: String, CaseIterable, Identifiable {
    case color, monochrome
    var id: String { rawValue }
    var title: String { self == .color ? "Grafana colors" : "Monochrome" }
}

enum BadgeStyle: String, CaseIterable, Identifiable {
    case badge, number, dot, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .badge: "Badge"
        case .number: "Number"
        case .dot: "Dot"
        case .none: "None"
        }
    }
}

enum CountMode: String, CaseIterable, Identifiable {
    case rules, instances
    var id: String { rawValue }
    var title: String { self == .rules ? "Firing rules" : "Firing instances" }
}

enum PrefKey {
    static let authMode = "authMode"
    static let serverURL = "serverURL"
    static let basicUser = "basicUser"

    static let iconColor = "iconColor"
    static let badgeStyle = "badgeStyle"
    static let severityColors = "severityColors"
    static let countMode = "countMode"
    static let dimWhenEmpty = "dimWhenEmpty"
    static let refreshInterval = "refreshInterval"
    static let notifyFiring = "notifyFiring"
    static let notifyResolved = "notifyResolved"
    static let notifySound = "notifySound"

    static let showPending = "filterShowPending"
    static let hideSilenced = "filterHideSilenced"
    static let minSeverity = "filterMinSeverity"
    static let includeFolders = "filterIncludeFolders"
    static let excludeFolders = "filterExcludeFolders"
    static let excludeGroups = "filterExcludeGroups"
    static let excludeRules = "filterExcludeRules"
    static let includeLabels = "filterIncludeLabels"
    static let excludeLabels = "filterExcludeLabels"
    static let showHidden = "showHiddenInList"
}

/// Typed access to UserDefaults. SwiftUI binds to the same keys with @AppStorage.
enum Prefs {
    static var store: UserDefaults { .standard }

    static func registerDefaults() {
        store.register(defaults: [
            PrefKey.authMode: AuthMode.token.rawValue,
            PrefKey.serverURL: "",
            PrefKey.basicUser: "",
            PrefKey.iconColor: IconColor.color.rawValue,
            PrefKey.badgeStyle: BadgeStyle.badge.rawValue,
            PrefKey.severityColors: true,
            PrefKey.countMode: CountMode.rules.rawValue,
            PrefKey.dimWhenEmpty: true,
            PrefKey.refreshInterval: 60.0,
            PrefKey.notifyFiring: true,
            PrefKey.notifyResolved: false,
            PrefKey.notifySound: true,
            PrefKey.showPending: false,
            PrefKey.hideSilenced: true,
            PrefKey.minSeverity: Severity.unknown.rawValue,
            PrefKey.includeFolders: "",
            PrefKey.excludeFolders: "",
            PrefKey.excludeGroups: "",
            PrefKey.excludeRules: "",
            PrefKey.includeLabels: "",
            PrefKey.excludeLabels: "",
            PrefKey.showHidden: false,
        ])
    }

    static var authMode: AuthMode { AuthMode(rawValue: store.string(forKey: PrefKey.authMode) ?? "") ?? .token }
    static var serverURL: String { store.string(forKey: PrefKey.serverURL) ?? "" }
    static var basicUser: String { store.string(forKey: PrefKey.basicUser) ?? "" }

    static var iconColor: IconColor { IconColor(rawValue: store.string(forKey: PrefKey.iconColor) ?? "") ?? .color }
    static var badgeStyle: BadgeStyle { BadgeStyle(rawValue: store.string(forKey: PrefKey.badgeStyle) ?? "") ?? .badge }
    static var severityColors: Bool { store.bool(forKey: PrefKey.severityColors) }
    static var countMode: CountMode { CountMode(rawValue: store.string(forKey: PrefKey.countMode) ?? "") ?? .rules }
    static var dimWhenEmpty: Bool { store.bool(forKey: PrefKey.dimWhenEmpty) }
    static var refreshInterval: TimeInterval { max(15, store.double(forKey: PrefKey.refreshInterval)) }
    static var notifyFiring: Bool { store.bool(forKey: PrefKey.notifyFiring) }
    static var notifyResolved: Bool { store.bool(forKey: PrefKey.notifyResolved) }
    static var notifySound: Bool { store.bool(forKey: PrefKey.notifySound) }

    static var filters: FilterSettings {
        FilterSettings(
            showPending: store.bool(forKey: PrefKey.showPending),
            hideSilenced: store.bool(forKey: PrefKey.hideSilenced),
            minSeverity: Severity(rawValue: store.integer(forKey: PrefKey.minSeverity)) ?? .unknown,
            includeFolders: patterns(PrefKey.includeFolders),
            excludeFolders: patterns(PrefKey.excludeFolders),
            excludeGroups: patterns(PrefKey.excludeGroups),
            excludeRules: patterns(PrefKey.excludeRules),
            includeLabels: patterns(PrefKey.includeLabels).compactMap(LabelMatcher.init),
            excludeLabels: patterns(PrefKey.excludeLabels).compactMap(LabelMatcher.init)
        )
    }

    /// Comma- or newline-separated list.
    static func patterns(_ key: String) -> [String] {
        (store.string(forKey: key) ?? "")
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Adds `value` to a comma-separated list pref, unless it's already there.
    static func append(_ value: String, to key: String) {
        let existing = patterns(key)
        guard !existing.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        store.set((existing + [value]).joined(separator: ", "), forKey: key)
    }
}

extension NSColor {
    // Grafana's icon gradient (orange at the top, yellow at the bottom).
    static let grafanaYellow = NSColor(srgbRed: 0.984, green: 0.792, blue: 0.039, alpha: 1)   // #FBCA0A
    static let grafanaOrange = NSColor(srgbRed: 0.941, green: 0.353, blue: 0.157, alpha: 1)   // #F05A28
    static let grafanaDark = NSColor(srgbRed: 0.094, green: 0.106, blue: 0.122, alpha: 1)     // #181B1F
}

extension Severity {
    var nsColor: NSColor {
        switch self {
        case .critical, .unknown: .systemRed
        case .warning: .systemOrange
        case .info: .systemBlue
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}
