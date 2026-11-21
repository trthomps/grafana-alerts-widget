import Foundation

/// `key=value` or `key!=value`, where value is a glob. A bare `value` matches any label's value.
struct LabelMatcher: Equatable {
    var key: String?
    var value: String
    var negated: Bool

    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "!=") {
            key = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            value = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            negated = true
        } else if let range = text.range(of: "=") {
            key = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            value = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            negated = false
        } else {
            key = nil
            value = text
            negated = false
        }
        if key?.isEmpty == true { return nil }
    }

    func matches(_ labels: [String: String]) -> Bool {
        guard let key else { return labels.values.contains { Glob.matches(value, $0) } }
        // A missing label matches an empty value (`team=` means "no team label").
        let present = labels[key].map { Glob.matches(value, $0) } ?? value.isEmpty
        return negated ? !present : present
    }

    var description: String { key.map { "\($0)\(negated ? "!=" : "=")\(value)" } ?? value }
}

/// What counts as an alert. Everything Grafana reports is still there on the server; this only
/// decides what shows in the list, counts toward the badge and triggers banners.
struct FilterSettings: Equatable {
    var showPending: Bool
    var hideSilenced: Bool
    var minSeverity: Severity
    var includeFolders: [String]
    var excludeFolders: [String]
    var excludeGroups: [String]
    var excludeRules: [String]
    var includeLabels: [LabelMatcher]
    var excludeLabels: [LabelMatcher]

    static let none = FilterSettings(showPending: true, hideSilenced: false, minSeverity: .unknown,
                                     includeFolders: [], excludeFolders: [], excludeGroups: [], excludeRules: [],
                                     includeLabels: [], excludeLabels: [])

    /// nil when the rule as a whole passes; otherwise why it's hidden.
    func ruleHiddenReason(_ rule: AlertRule) -> String? {
        if !includeFolders.isEmpty, !Glob.any(includeFolders, matches: rule.folder) { return "Folder \(rule.folder)" }
        if Glob.any(excludeFolders, matches: rule.folder) { return "Folder \(rule.folder)" }
        if Glob.any(excludeGroups, matches: rule.group) || Glob.any(excludeGroups, matches: "\(rule.folder)/\(rule.group)") {
            return "Group \(rule.group)"
        }
        if excludeRules.contains(where: { Glob.matches($0.contains("*") ? $0 : "*\($0)*", rule.name) }) { return "Rule name" }
        return nil
    }

    /// nil when the instance passes; otherwise why it's hidden.
    func instanceHiddenReason(_ instance: AlertInstance) -> String? {
        if instance.state == .normal { return "Normal" }
        if instance.state == .pending, !showPending { return "Pending" }
        if hideSilenced, instance.silenced { return "Silenced" }
        // Alerts without a severity label always pass: there's nothing to compare.
        if minSeverity != .unknown, instance.severity != .unknown, instance.severity < minSeverity {
            return "Severity \(instance.labels["severity"] ?? "")"
        }
        if !includeLabels.isEmpty, !includeLabels.contains(where: { $0.matches(instance.labels) }) { return "Labels" }
        if let matcher = excludeLabels.first(where: { $0.matches(instance.labels) }) { return matcher.description }
        return nil
    }
}

/// Case-insensitive shell-style patterns: `Staging*`, `*-warnings`.
enum Glob {
    static func any(_ patterns: [String], matches text: String) -> Bool {
        patterns.contains { matches($0, text) }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        var regex = "^"
        for character in pattern {
            switch character {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        regex += "$"
        return text.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
