# Grafana Alerts

A macOS menu bar app for Grafana-managed alerts. It shows a badge with the number of firing alerts, a list you can click through to Grafana, a right-click menu to silence alerts, macOS banners when alerts start firing, and filters so only the alerts you care about count.

![Menu bar styles, light](docs/menubar-light.png)
![Menu bar styles, dark](docs/menubar-dark.png)

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
make install      # builds "Grafana Alerts.app", copies it to ~/Applications, launches it
```

`make app` builds into `build/` without installing. Opening the app again from Spotlight or Finder brings up Settings, which helps when a menu bar manager has hidden the item.

## Signing in

Settings → Account takes your Grafana URL (pasting any Grafana page URL works; the path is stripped) and one of:

| Mode | Notes |
| --- | --- |
| **Service account token** (recommended) | Administration → Users and access → Service accounts → *Add service account*, then *Add service account token*. **Viewer** is enough to read alerts. **Editor** also lets you silence alerts from the menu. The *Create Token in Grafana…* button opens that page. |
| **Username & password** | Grafana basic auth. This doesn't work for SSO-only accounts. |
| **No auth** | For instances with anonymous access. |

Secrets are stored in the login Keychain through `/usr/bin/security`. They're piped over stdin, so they never appear in a process listing.

If nothing is configured, the app falls back to the `GRAFANA_URL` and `GRAFANA_SERVICE_ACCOUNT_TOKEN` (or `GRAFANA_API_KEY`) environment variables, which `mcp-grafana` also uses. This helps with `--print`.

## Using it

- **Click** the icon to see the list. Each row is an alert rule: its state, name, the rendered summary, folder › group, instance count, severity, and how long it has been active. Click a row to open the rule in Grafana. Click the chevron to see each instance's summary and the labels that set it apart.
- **Right-click a row** (or an instance) to open its runbook or dashboard panel, silence it for 1 hour, 4 hours, 1 day or 1 week, hide its rule, folder or group, or copy its name or labels.
- **Right-click the icon** for Refresh, Open Firing Alerts / Silences in Browser, Settings and Quit.
- **Terminal**: `GrafanaAlerts --print` prints what the menu bar would show, with your filters applied.

### Badge

- **Count what**: *firing rules* (the default, and what Grafana's alert list counts) or *firing instances*. A rule firing for 5 hosts counts as 1 rule or 5 instances.
- The count is red when anything critical (or unlabeled) is firing and orange when only warnings are firing. You can turn severity colors off.
- Styles: badge, number, dot or none. The icon can use Grafana colors or monochrome.
- Silenced and pending alerts never count. The icon dims when nothing is firing and while loading. A gray dot means an error, and the popover explains it.

### Notifications

Banners are on by default for alerts that start firing, grouped per rule (a rule that starts firing for 3 hosts posts one banner). You can also get a banner when an alert resolves. Banners only cover alerts that pass your filters and aren't silenced. Clicking a banner opens the rule. Changing filters doesn't trigger banners.

## Filters

Settings → Filters decides what shows, counts and notifies. Nothing changes in Grafana.

- **State**: show pending alerts (listed, never counted), hide silenced and inhibited alerts (on by default), minimum severity (alerts without a `severity` label always show).
- **Folders, groups and rules**: an allow-list and a block-list of folders, plus hidden groups and rule names. One-click "Hide" buttons appear for the folders currently firing.
- **Labels**: *Only alerts with* and *Hide alerts with*, written as `key=value`, `key!=value`, or a bare `value` that matches any label. One-click buttons offer the labels on current alerts.

All lists are comma-separated, case-insensitive, and accept `*` globs. Label filters apply to each instance. A rule appears when at least one of its instances passes, and the row says how many instances were filtered out. The popover footer shows how many rules are hidden and can show them inline.

## Development

```sh
swift build
swift run GrafanaAlerts --print                  # live list in the terminal
swift run GrafanaAlerts --render-previews docs   # regenerate the images above
GRAFANA_ALERTS_DEBUG=1 "build/Grafana Alerts.app/Contents/MacOS/GrafanaAlerts"   # log requests
```

| File | What's in it |
| --- | --- |
| `GrafanaAPI.swift` | Rules, Alertmanager alerts, creating silences, health |
| `Auth.swift` | Credential modes, URL normalization, Keychain |
| `Models.swift` | Rule/instance types, state and severity parsing |
| `Filters.swift` | Filter rules, label matchers, globs |
| `AlertStore.swift` | Polling, silence matching, filtering, banners, silencing |
| `Logo.swift`, `GrafanaIconPath.swift`, `SVGPath.swift` | Grafana icon (drawn from its SVG path), menu bar renderer, app icon |
| `StatusItemController.swift`, `PopoverView.swift`, `SettingsView.swift` | UI |

## Porting notes (for the Plasma 6 version)

The behavior that has to carry over:

1. **Rules**: `GET {base}/api/prometheus/grafana/api/v1/rules?state=firing&state=pending&state=recovering` with `Authorization: Bearer <token>`. Grafana filters both rules and their `alerts[]` to those states. Walk `data.groups[]`, where `file` is the folder title and `name` is the group, then `rules[]`, which has `uid`, `name`, `state`, `health`, `labels`, `annotations` and `alerts[]`. Skip rules whose `type` isn't `alerting`.
2. **Instance state**: `alerts[].state` is `Alerting`, `Alerting (NoData)`, `Alerting (Error)`, `Pending`, `Recovering` or `Normal`. Anything starting with `Alerting` is firing, and the text in parentheses is shown as a chip. `activeAt` can have nanoseconds, or be `0001-01-01…` when unset.
3. **Silences**: `GET {base}/api/alertmanager/grafana/api/v2/alerts?active=true&silenced=true&inhibited=true`. Entries with `status.state == "suppressed"` are silenced or inhibited. Match them to instances by `labels.__alert_rule_uid__` plus the sorted labels that don't start with `__`. If this call fails, carry on and show a warning.
4. **Silence action**: `POST {base}/api/alertmanager/grafana/api/v2/silences` with matchers `__alert_rule_uid__=<uid>`, plus every non-`__` label when silencing a single instance.
5. **Count**: rules (or instances) that are firing or recovering, not silenced, and pass the filters. The badge color comes from the worst `severity` among them.
6. **Banners**: diff the counted instance IDs (`ruleUID|labelKey`) against the previous poll. Don't post on the first poll, and reset the baseline when filters change.
7. **Links**: rule `{base}/alerting/grafana/{uid}/view`, firing list `{base}/alerting/list?search=state:firing`, silences `{base}/alerting/silences`, runbook `annotations.runbook_url`, panel `/d/{__dashboardUid__}?viewPanel={__panelId__}`.
