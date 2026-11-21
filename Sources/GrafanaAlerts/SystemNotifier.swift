import Foundation
import UserNotifications

/// macOS banners when alerts start firing (and optionally resolve). Clicking one opens the rule.
@MainActor
enum SystemNotifier {
    /// UNUserNotificationCenter only works inside an app bundle (not under `swift run`).
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    private static let delegate = Delegate()
    static var onOpen: ((String) -> Void)?

    static func setUp(onOpen: @escaping (String) -> Void) {
        guard available else { return }
        self.onOpen = onOpen
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func postFiring(_ items: [(AlertRule, [AlertInstance])], baseURL: URL?) {
        guard available, !items.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        if items.count > 4 {
            let content = base()
            content.title = "\(items.count) alerts started firing"
            content.body = items.prefix(4).map(\.0.name).joined(separator: "\n")
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return
        }
        for (rule, instances) in items {
            let content = base()
            let severity = instances.map(\.severity).max() ?? .unknown
            content.title = (severity == .critical ? "🔴 " : severity == .warning ? "🟠 " : "🔥 ") + rule.name
            content.subtitle = [rule.folder, instances.count > 1 ? "\(instances.count) instances" : nil]
                .compactMap { $0 }.joined(separator: " · ")
            if instances.count == 1 {
                content.body = instances[0].summary ?? labelLine(instances[0], rule: rule)
            } else {
                content.body = instances.prefix(4).map { $0.summary ?? labelLine($0, rule: rule) }.joined(separator: "\n")
            }
            content.userInfo = ["rule": rule.uid]
            content.threadIdentifier = rule.uid
            center.add(UNNotificationRequest(identifier: "firing-\(rule.uid)-\(Date().timeIntervalSince1970)",
                                             content: content, trigger: nil))
        }
    }

    static func postResolved(_ items: [(String, [AlertInstance])]) {
        guard available, !items.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        for (name, instances) in items.prefix(5) {
            let content = base()
            content.title = "✅ Resolved: \(name)"
            content.body = instances.count == 1 ? (instances[0].summary ?? "") : "\(instances.count) instances resolved"
            if let uid = instances.first?.ruleUID {
                content.userInfo = ["rule": uid]
                content.threadIdentifier = uid
            }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func base() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if Prefs.notifySound { content.sound = .default }
        return content
    }

    private static func labelLine(_ instance: AlertInstance, rule: AlertRule) -> String {
        let labels = instance.distinguishingLabels(common: rule.labels)
        return labels.isEmpty ? instance.state.title : labels.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let uid = response.notification.request.content.userInfo["rule"] as? String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let uid { SystemNotifier.onOpen?(uid) }
                }
            }
            completionHandler()
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .list, .sound])
        }
    }
}
