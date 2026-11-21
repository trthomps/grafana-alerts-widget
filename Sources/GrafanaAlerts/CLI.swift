import AppKit

@MainActor
enum CLI {
    /// Fetches once with the app's settings and prints what the menu bar would show.
    static func printAlerts() -> Int32 {
        let store = AlertStore()
        var finished = false
        Task {
            await store.refresh(userInitiated: true, quiet: true)
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        if let error = store.error {
            FileHandle.standardError.write(Data("\(error.title): \(error.message)\n".utf8))
            if store.lastFetched == nil { return 1 }
        }
        let color = isatty(STDOUT_FILENO) != 0
        func dim(_ text: String) -> String { color ? "\u{1B}[2m\(text)\u{1B}[0m" : text }
        func bold(_ text: String) -> String { color ? "\u{1B}[1m\(text)\u{1B}[0m" : text }
        func tint(_ text: String, _ severity: Severity, _ state: AlertState) -> String {
            guard color else { return text }
            let code = state == .pending ? "33" : severity == .warning ? "33" : severity == .info ? "34" : "31"
            return "\u{1B}[\(code)m\(text)\u{1B}[0m"
        }

        print(bold("Grafana alerts") + dim("  ·  \(store.serverURL?.absoluteString ?? "")  ·  \(store.credentialSource ?? "")"))
        let noun = Prefs.countMode == .rules ? "rules" : "instances"
        print("\(store.badgeCount) firing \(noun) shown, \(store.hidden.count) rules hidden by filters\n")
        if let warning = store.silenceWarning { print(dim(warning) + "\n") }
        let now = Date()
        for item in store.shown {
            let marker = item.allSilenced ? "◌" : item.state == .pending ? "○" : "●"
            let since = item.since.map { "  " + Fmt.ago($0, now: now, short: true) } ?? ""
            print("\(tint(marker, item.severity, item.state)) \(bold(item.rule.name))\(dim(since))")
            print("  " + dim("\(item.rule.folder) › \(item.rule.group) · \(item.instances.count) instance\(item.instances.count == 1 ? "" : "s")"
                + (item.hiddenInstances > 0 ? " (+\(item.hiddenInstances) hidden)" : "")))
            let common = item.rule.commonLabels
            for instance in item.instances {
                let labels = instance.distinguishingLabels(common: common).map { "\($0.0)=\($0.1)" }.joined(separator: " ")
                let state = instance.silenced ? " [silenced]" : instance.state == .firing ? "" : " [\(instance.state.title.lowercased())]"
                let reason = instance.reason.map { " (\($0))" } ?? ""
                print("    - \(instance.summary ?? labels)\(dim(state + reason))")
                if instance.summary != nil, !labels.isEmpty { print("      " + dim(labels)) }
            }
            if let url = store.ruleURL(item.rule.uid) { print("  " + dim(url.absoluteString)) }
        }
        if !store.hidden.isEmpty {
            let reasons = Dictionary(grouping: store.hidden.compactMap(\.hiddenReason), by: { $0 })
                .mapValues(\.count).sorted { $0.value > $1.value }
            print(dim("\nHidden: " + reasons.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")))
        }
        return 0
    }

    static func renderPreviews(to directory: String) {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)!
            var models: [MenuBarModel] = []
            for color in IconColor.allCases {
                for badge in BadgeStyle.allCases {
                    models.append(MenuBarModel(state: .ok, count: 4, severity: .critical, color: color, badge: badge))
                }
                models.append(MenuBarModel(state: .ok, count: 2, severity: .warning, color: color, badge: .badge))
                models.append(MenuBarModel(state: .ok, count: 0, color: color, badge: .badge))
                models.append(MenuBarModel(state: .error, count: 0, color: color, badge: .badge))
            }
            let scale: CGFloat = 4
            let gap: CGFloat = 14
            let width = models.reduce(gap) { $0 + MenuBarRenderer.width(for: $1) + gap }
            let height: CGFloat = 22 * 2
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let ctx = context.cgContext
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(name == "dark" ? CGColor(gray: 0.16, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var x = gap
            for model in models {
                let w = MenuBarRenderer.width(for: model)
                ctx.saveGState()
                ctx.translateBy(x: x, y: 11)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                MenuBarRenderer.draw(model, in: ctx, bounds: CGRect(x: 0, y: 0, width: w, height: 22), appearance: appearance)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
                x += w + gap
            }
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("menubar-\(name).png"))
            }
        }
        let icon = AppIcon.bitmap(side: 512) { ctx, side in AppIcon.draw(ctx, side: side) }
        if let data = icon.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent("icon.png"))
        }
    }
}
