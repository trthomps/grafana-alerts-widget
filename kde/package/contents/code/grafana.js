.pragma library

// Port of Models.swift, Filters.swift, the parsing in GrafanaAPI.swift, URL handling in Auth.swift,
// the list building and banner diffing in AlertStore.swift, and Fmt.
// Plain JS so it can be unit-tested with node (see kde/test/grafana.test.js).

// MARK: - State and severity (Models.swift)

/// Most urgent first.
var STATES = ["firing", "recovering", "pending", "normal"];

var stateTitles = { firing: "Firing", recovering: "Recovering", pending: "Pending", normal: "Normal" };

function stateRank(s) { var i = STATES.indexOf(s); return i < 0 ? 3 : i; }

/// Instance states: "Alerting", "Alerting (NoData)", "Alerting (Error)", "Pending", "Recovering",
/// "Normal", "NoData", "Error".
function instanceState(raw) {
    var lower = String(raw || "").toLowerCase();
    // Plain "NoData"/"Error" means the rule's no-data/error handling is set to that state:
    // Grafana still notifies (DatasourceNoData / DatasourceError), so treat them as firing.
    if (lower.indexOf("alerting") === 0 || lower.indexOf("firing") === 0 || lower === "nodata" || lower === "error")
        return "firing";
    if (lower.indexOf("recovering") === 0) return "recovering";
    if (lower.indexOf("pending") === 0) return "pending";
    return "normal";
}

/// Rule states: "firing", "pending", "recovering", "inactive".
function ruleState(raw) {
    var lower = String(raw || "").toLowerCase();
    return STATES.indexOf(lower) >= 0 ? lower : "normal";
}

/// Firing and recovering alerts are still being sent to contact points.
function isActive(state) { return state === "firing" || state === "recovering"; }

/// "Alerting (NoData)" → "NoData"; plain "NoData" / "Error" → themselves.
function stateReason(raw) {
    var s = String(raw || "");
    if (s.toLowerCase() === "nodata") return "NoData";
    if (s.toLowerCase() === "error") return "Error";
    var open = s.indexOf("("), close = s.lastIndexOf(")");
    if (open < 0 || close < 0 || open >= close) return null;
    return nonEmpty(s.slice(open + 1, close));
}

/// 0 unknown, 1 info, 2 warning, 3 critical. Higher is worse.
var SEVERITY = { unknown: 0, info: 1, warning: 2, critical: 3 };
var severityTitles = ["Any", "Info", "Warning", "Critical"];

function severity(label) {
    if (label === null || label === undefined || label === "") return 0;
    switch (String(label).toLowerCase()) {
    case "critical": case "crit": case "page": case "p1": case "high": case "error": case "emergency":
    case "alert": case "fatal": case "disaster":
        return 3;
    case "warning": case "warn": case "medium": case "p2": case "p3": case "major": case "minor": case "average":
        return 2;
    default:
        return 1;
    }
}

function nonEmpty(v) {
    if (typeof v !== "string") return null;
    var t = v.trim();
    return t === "" ? null : t;
}

/// Labels Grafana and Alertmanager agree on (internal `__*__` labels dropped), sorted.
function labelKey(labels) {
    return Object.keys(labels || {}).filter(function (k) { return k.indexOf("__") !== 0; }).sort()
        .map(function (k) { return k + "=" + labels[k]; }).join(",");
}

function instanceID(ruleUID, labels) { return ruleUID + "|" + labelKey(labels); }

function summaryOf(annotations) {
    annotations = annotations || {};
    return nonEmpty(annotations.summary) || nonEmpty(annotations.description);
}

/// Labels shared by every instance, so rows only show what tells instances apart.
function commonLabels(rule) {
    if (!rule.instances.length) return rule.labels;
    var common = Object.assign({}, rule.instances[0].labels);
    rule.instances.slice(1).forEach(function (inst) {
        Object.keys(common).forEach(function (k) { if (inst.labels[k] !== common[k]) delete common[k]; });
    });
    return common;
}

/// [[key, value]] worth showing next to an instance: not internal, not the rule's own name/folder,
/// and not shared by every instance of the rule.
function distinguishingLabels(instance, common) {
    return Object.keys(instance.labels).filter(function (k) {
        return k.indexOf("__") !== 0 && k !== "alertname" && k !== "grafana_folder" && common[k] !== instance.labels[k];
    }).sort().map(function (k) { return [k, instance.labels[k]]; });
}

function labelText(pairs, sep) {
    return pairs.map(function (p) { return p[0] + "=" + p[1]; }).join(sep === undefined ? "  " : sep);
}

// MARK: - Parsing (GrafanaAPI.swift)

/// Milliseconds since epoch, or null. Handles fractions of any length (Grafana sends nanoseconds),
/// and treats Go's zero time ("0001-01-01T00:00:00Z") as unset.
function parseDate(v) {
    if (typeof v !== "string" || v === "") return null;
    var s = v.replace(/(\.\d{1,3})\d*/, "$1").replace(/([+-]\d\d)(\d\d)$/, "$1:$2");
    var t = Date.parse(s);
    return isNaN(t) || t <= 0 ? null : t;
}

function strMap(o) {
    var out = {};
    if (o && typeof o === "object") Object.keys(o).forEach(function (k) { if (typeof o[k] === "string") out[k] = o[k]; });
    return out;
}

function decodeJSON(text, what) {
    try { return JSON.parse(text); } catch (e) {
        if (String(text).slice(0, 200).toLowerCase().indexOf("<html") >= 0)
            throw apiError("decoding", "Got a web page instead of JSON from " + what + ". Is the server URL right?");
        throw apiError("decoding", "Couldn't read " + what + ".");
    }
}

/// GET /api/prometheus/grafana/api/v1/rules → [rule]. Skips recording rules.
function parseRules(text) {
    var o = decodeJSON(text, "the alert rules");
    var groups = o && o.data && Array.isArray(o.data.groups) ? o.data.groups : null;
    if (!groups) throw apiError("decoding", "Couldn't read the alert rules.");
    var rules = [];
    groups.forEach(function (g) {
        (Array.isArray(g.rules) ? g.rules : []).forEach(function (r) {
            if (!r || (r.type && r.type !== "alerting") || typeof r.uid !== "string" || !r.uid) return;
            var uid = r.uid;
            var instances = (Array.isArray(r.alerts) ? r.alerts : []).map(function (a) {
                var labels = strMap(a.labels);
                return {
                    id: instanceID(uid, labels),
                    ruleUID: uid,
                    labels: labels,
                    annotations: strMap(a.annotations),
                    state: instanceState(a.state),
                    reason: stateReason(a.state),
                    activeAt: parseDate(a.activeAt),
                    value: typeof a.value === "string" ? a.value : null,
                    silenced: false
                };
            });
            rules.push({
                uid: uid,
                name: typeof r.name === "string" ? r.name : uid,
                folder: typeof g.file === "string" ? g.file : "",
                folderUID: r.folderUid || g.folderUid || null,
                group: typeof g.name === "string" ? g.name : "",
                state: ruleState(r.state),
                health: r.health || "ok",
                lastError: nonEmpty(r.lastError),
                labels: strMap(r.labels),
                annotations: strMap(r.annotations),
                instances: instances,
                isPaused: r.isPaused === true
            });
        });
    });
    return rules;
}

/// Most to least complete. Grafana answers 400 "unknown state" for a state it doesn't have
/// (`recovering` is recent; `nodata`/`error` arrived in 10.x), so step down until one works.
var STATE_SETS = [
    ["firing", "pending", "recovering", "nodata", "error"],
    ["firing", "pending", "nodata", "error"],
    ["firing", "pending"]
];

/// How long a stepped-down state list is trusted before trying the full one again (Grafana may
/// have been upgraded).
var STATE_SET_RETRY = 60 * 60 * 1000;

/// Which STATE_SETS index to start with, given the cached { index, at } for the server.
function stateSetIndex(cached, now) {
    if (!cached || now - cached.at >= STATE_SET_RETRY) return 0;
    return cached.index;
}

/// Whether a rules request that failed with `err` should be retried with STATE_SETS[index + 1].
function shouldStepDown(err, index) {
    return index + 1 < STATE_SETS.length && err && err.kind === "http" && err.status === 400
        && /state/i.test(err.detail || "");
}

/// GET /api/alertmanager/grafana/api/v2/alerts → { instanceID: true } for silenced or inhibited ones.
function parseSuppressed(text) {
    var list = decodeJSON(text, "Alertmanager's alerts");
    if (!Array.isArray(list)) throw apiError("decoding", "Couldn't read Alertmanager's alerts.");
    var ids = {};
    list.forEach(function (a) {
        if (!a || !a.status || a.status.state !== "suppressed") return;
        var labels = strMap(a.labels);
        var uid = labels.__alert_rule_uid__;
        if (uid) ids[instanceID(uid, labels)] = true;
    });
    return ids;
}

/// The POST body for /api/alertmanager/grafana/api/v2/silences: the whole rule, or one instance
/// when `labels` is given.
function silenceBody(ruleUID, labels, seconds, comment, now) {
    var matchers = [{ name: "__alert_rule_uid__", value: ruleUID, isRegex: false, isEqual: true }];
    Object.keys(labels || {}).sort().forEach(function (k) {
        if (k.indexOf("__") !== 0) matchers.push({ name: k, value: labels[k], isRegex: false, isEqual: true });
    });
    return {
        matchers: matchers,
        startsAt: isoSeconds(now),
        endsAt: isoSeconds(now + seconds * 1000),
        createdBy: "Grafana Alerts (KDE)",
        comment: comment
    };
}

function parseVersion(text) {
    try { var o = JSON.parse(text); return o && typeof o.version === "string" ? o.version : null; } catch (e) { return null; }
}

// MARK: - Server URLs (Auth.swift, AlertStore.swift)

/// "grafana.example.com/" → "https://grafana.example.com". Keeps a sub-path for Grafana served
/// under one (`https://example.com/grafana`). Strips a pasted page path like `/alerting/list?...`.
function normalizeServer(text) {
    var s = String(text || "").trim();
    if (!s) return null;
    if (s.indexOf("://") < 0) s = "https://" + s;
    var m = s.match(/^(https?):\/\/([^\/?#\s]+)([^?#\s]*)/i);
    if (!m) return null;
    var path = m[3];
    ["/alerting", "/d/", "/dashboards", "/explore", "/login", "/a/", "/admin", "/connections"].forEach(function (marker) {
        var i = path.indexOf(marker);
        if (i >= 0) path = path.slice(0, i);
    });
    path = path.replace(/\/+$/, "");
    return m[1].toLowerCase() + "://" + m[2] + path;
}

/// `{base}/{path}?query`, with repeated keys for array values.
function joinURL(base, path, query) {
    var url = base + "/" + String(path).replace(/^\/+/, "");
    var parts = [];
    Object.keys(query || {}).sort().forEach(function (k) {
        [].concat(query[k]).forEach(function (v) { parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(v)); });
    });
    return parts.length ? url + "?" + parts.join("&") : url;
}

function ruleURL(base, uid) { return base ? joinURL(base, "alerting/grafana/" + encodeURIComponent(uid) + "/view") : null; }
function firingListURL(base) { return base ? joinURL(base, "alerting/list", { search: "state:firing" }) : null; }
function silencesURL(base) { return base ? joinURL(base, "alerting/silences") : null; }
function createTokenURL(base) { return base ? joinURL(base, "org/serviceaccounts/create") : null; }

function httpURL(v) { var s = nonEmpty(v); return s && /^https?:\/\//i.test(s) ? s : null; }

function runbookURL(rule, instance) {
    return httpURL(rule.annotations.runbook_url) || (instance ? httpURL(instance.annotations.runbook_url) : null);
}

/// The dashboard panel the rule is linked to, if any.
function dashboardURL(base, rule) {
    if (!base) return null;
    var a = Object.assign({}, rule.instances.length ? rule.instances[0].annotations : {}, rule.annotations);
    var dash = nonEmpty(a.__dashboardUid__);
    if (!dash) return null;
    var panel = nonEmpty(a.__panelId__);
    return joinURL(base, "d/" + encodeURIComponent(dash), panel ? { viewPanel: panel } : {});
}

// MARK: - Filters (Filters.swift)

/// Comma- or newline-separated list, as stored in the config.
function patterns(text) {
    return String(text || "").split(/[,\n]/).map(function (s) { return s.trim(); })
        .filter(function (s) { return s.length > 0; });
}

/// Adds `value` to a comma-separated list unless it's already there (case-insensitive).
function appendPattern(text, value) {
    var list = patterns(text);
    var lower = value.toLowerCase();
    if (list.some(function (p) { return p.toLowerCase() === lower; })) return list.join(", ");
    return list.concat([value]).join(", ");
}

function escapeRegex(s) { return s.replace(/[.*+?^${}()|[\]\\\/]/g, "\\$&"); }

/// Case-insensitive shell-style patterns: `Staging*`, `*-warnings`.
function globMatches(pattern, text) {
    var re = "^";
    for (var i = 0; i < pattern.length; i++) {
        var c = pattern.charAt(i);
        re += c === "*" ? "[\\s\\S]*" : c === "?" ? "[\\s\\S]" : escapeRegex(c);
    }
    return new RegExp(re + "$", "i").test(text);
}

function globAny(list, text) {
    for (var i = 0; i < list.length; i++) if (globMatches(list[i], text)) return true;
    return false;
}

/// A pattern matching `text` exactly (as nearly as list syntax allows): commas would split the list
/// and `*`/`?` would act as wildcards, so each becomes `?` (any one character).
function globLiteral(text) { return String(text).replace(/[,*?\r\n]/g, "?"); }

/// A `key=value` pattern matching that label exactly: the value is escaped like globLiteral.
function labelLiteral(pair) {
    var i = pair.indexOf("=");
    return i < 0 ? globLiteral(pair) : globLiteral(pair.slice(0, i)) + "=" + globLiteral(pair.slice(i + 1));
}

/// `key=value` or `key!=value`, where value is a glob. A bare `value` matches any label's value.
function parseMatcher(text) {
    var t = String(text).trim();
    if (!t) return null;
    var m;
    var i = t.indexOf("!=");
    var j = t.indexOf("=");
    // Split on whichever operator comes first, so `expr=a!=b` is key `expr`, value `a!=b`.
    if (i >= 0 && i < j) m = { key: t.slice(0, i).trim(), value: t.slice(i + 2).trim(), negated: true };
    else if (j >= 0) m = { key: t.slice(0, j).trim(), value: t.slice(j + 1).trim(), negated: false };
    else m = { key: null, value: t, negated: false };
    if (m.key === "") return null;
    return m;
}

function matcherMatches(m, labels) {
    if (m.key === null) {
        return Object.keys(labels).some(function (k) { return globMatches(m.value, labels[k]); });
    }
    // A missing label matches an empty value (`team=` means "no team label").
    var present = Object.prototype.hasOwnProperty.call(labels, m.key) ? globMatches(m.value, labels[m.key]) : m.value === "";
    return m.negated ? !present : present;
}

function matcherText(m) { return m.key === null ? m.value : m.key + (m.negated ? "!=" : "=") + m.value; }

/// Turns the widget's config into a filter object.
function filtersFromConfig(c) {
    var matchers = function (t) { return patterns(t).map(parseMatcher).filter(function (m) { return m !== null; }); };
    var uids = {};
    patterns(c.filterHiddenRuleUIDs).forEach(function (u) { uids[u] = true; });
    return {
        showPending: !!c.filterShowPending,
        hideSilenced: !!c.filterHideSilenced,
        minSeverity: Math.max(0, Math.min(3, Number(c.filterMinSeverity) || 0)),
        includeFolders: patterns(c.filterIncludeFolders),
        excludeFolders: patterns(c.filterExcludeFolders),
        excludeGroups: patterns(c.filterExcludeGroups),
        excludeRules: patterns(c.filterExcludeRules),
        hiddenRuleUIDs: uids,
        includeLabels: matchers(c.filterIncludeLabels),
        excludeLabels: matchers(c.filterExcludeLabels)
    };
}

/// null when the rule as a whole passes; otherwise why it's hidden.
function ruleHiddenReason(f, rule) {
    if (f.hiddenRuleUIDs[rule.uid]) return "Hidden rule";
    if (f.includeFolders.length && !globAny(f.includeFolders, rule.folder)) return "Folder " + rule.folder;
    if (globAny(f.excludeFolders, rule.folder)) return "Folder " + rule.folder;
    if (globAny(f.excludeGroups, rule.group) || globAny(f.excludeGroups, rule.folder + "/" + rule.group))
        return "Group " + rule.group;
    for (var i = 0; i < f.excludeRules.length; i++) {
        var p = f.excludeRules[i];
        if (globMatches(p.indexOf("*") >= 0 ? p : "*" + p + "*", rule.name)) return "Rule name";
    }
    return null;
}

/// null when the instance passes; otherwise why it's hidden.
function instanceHiddenReason(f, inst) {
    if (inst.state === "normal") return "Normal";
    if (inst.state === "pending" && !f.showPending) return "Pending";
    if (f.hideSilenced && inst.silenced) return "Silenced";
    // Alerts without a severity label always pass: there's nothing to compare.
    var sev = severity(inst.labels.severity);
    if (f.minSeverity > 0 && sev > 0 && sev < f.minSeverity) return "Severity " + (inst.labels.severity || "");
    if (f.includeLabels.length && !f.includeLabels.some(function (m) { return matcherMatches(m, inst.labels); }))
        return "Labels";
    for (var i = 0; i < f.excludeLabels.length; i++)
        if (matcherMatches(f.excludeLabels[i], inst.labels)) return matcherText(f.excludeLabels[i]);
    return null;
}

// MARK: - List items (RuleItem in AlertStore.swift)

function makeItem(rule, instances, hiddenInstances, hiddenReason) {
    var state = instances.length
        ? instances.reduce(function (s, i) { return stateRank(i.state) < stateRank(s) ? i.state : s; }, "normal")
        : rule.state;
    var sev = instances.length
        ? Math.max.apply(null, instances.map(function (i) { return severity(i.labels.severity); }))
        : severity(rule.labels.severity);
    var times = instances.map(function (i) { return i.activeAt; }).filter(function (t) { return t !== null; });
    var worst = instances.reduce(function (w, i) {
        return w === null || severity(i.labels.severity) > severity(w.labels.severity) ? i : w;
    }, null);
    var reasonInst = instances.filter(function (i) { return i.reason !== null; })[0];
    return {
        id: rule.uid,
        rule: rule,
        instances: instances,
        hiddenInstances: hiddenInstances,
        hiddenReason: hiddenReason,
        state: state,
        severity: sev,
        severityLabel: (worst && worst.labels.severity) || rule.labels.severity || null,
        reason: reasonInst ? reasonInst.reason : null,
        since: times.length ? Math.min.apply(null, times) : null,
        latest: times.length ? Math.max.apply(null, times) : null,
        allSilenced: instances.length > 0 && instances.every(function (i) { return i.silenced; }),
        // What the badge counts: active and not silenced.
        counted: instances.filter(function (i) { return isActive(i.state) && !i.silenced; }),
        hasActive: instances.some(function (i) { return isActive(i.state); }),
        summary: (instances.length ? summaryOf(instances[0].annotations) : null) || nonEmpty(rule.annotations.summary),
        common: commonLabels(rule)
    };
}

/// Firing before pending, worst severity first, then most recently started.
function itemOrder(a, b) {
    if (a.state !== b.state) return stateRank(a.state) - stateRank(b.state);
    if (a.allSilenced !== b.allSilenced) return a.allSilenced ? 1 : -1;
    if (a.severity !== b.severity) return b.severity - a.severity;
    var at = a.latest || 0, bt = b.latest || 0;
    if (at !== bt) return bt - at;
    return a.rule.name.toLowerCase().localeCompare(b.rule.name.toLowerCase());
}

function instanceOrder(a, b) {
    if (a.state !== b.state) return stateRank(a.state) - stateRank(b.state);
    if (a.silenced !== b.silenced) return a.silenced ? 1 : -1;
    var ak = labelKey(a.labels), bk = labelKey(b.labels);
    return ak < bk ? -1 : ak > bk ? 1 : 0;
}

/// Splits rules into { shown, hidden } items, in list order.
function partition(rules, f) {
    var shown = [], hidden = [];
    rules.forEach(function (rule) {
        var candidates = rule.instances.filter(function (i) { return i.state !== "normal"; });
        var ruleReason = ruleHiddenReason(f, rule);
        if (ruleReason !== null) {
            if (candidates.length) hidden.push(makeItem(rule, candidates.slice().sort(instanceOrder), 0, ruleReason));
            return;
        }
        var passing = [], reasons = {};
        candidates.forEach(function (i) {
            var r = instanceHiddenReason(f, i);
            if (r === null) passing.push(i);
            else reasons[r] = (reasons[r] || 0) + 1;
        });
        if (!passing.length) {
            if (!candidates.length) return;
            // The most common reason among its instances.
            var common = Object.keys(reasons).sort(function (a, b) { return reasons[b] - reasons[a]; })[0] || null;
            hidden.push(makeItem(rule, candidates.slice().sort(instanceOrder), 0, common));
        } else {
            shown.push(makeItem(rule, passing.sort(instanceOrder), candidates.length - passing.length, null));
        }
    });
    shown.sort(itemOrder);
    hidden.sort(itemOrder);
    return { shown: shown, hidden: hidden };
}

/// Copies silenced flags onto each instance from Alertmanager's suppressed IDs.
function applySilences(rules, suppressed) {
    return rules.map(function (r) {
        return Object.assign({}, r, {
            instances: r.instances.map(function (i) { return Object.assign({}, i, { silenced: !!suppressed[i.id] }); })
        });
    });
}

/// Silenced instance IDs from a previous poll, for when Alertmanager doesn't answer.
function silencedIDs(rules) {
    var ids = {};
    rules.forEach(function (r) { r.instances.forEach(function (i) { if (i.silenced) ids[i.id] = true; }); });
    return ids;
}

// MARK: - Counts (AlertStore.swift)

/// "rules" | "instances"
function badgeCount(shown, mode) {
    if (mode === "instances") return shown.reduce(function (n, i) { return n + i.counted.length; }, 0);
    return shown.filter(function (i) { return i.counted.length > 0; }).length;
}

function pendingCount(shown) {
    return shown.filter(function (i) { return !i.hasActive && i.state === "pending"; }).length;
}

/// Worst severity among counted alerts (unknown sorts as critical), or null if nothing counts.
function worstSeverity(shown) {
    var worst = null;
    shown.forEach(function (item) {
        item.counted.forEach(function (i) {
            var s = severity(i.labels.severity) || 3;
            if (worst === null || s > worst) worst = s;
        });
    });
    return worst;
}

// MARK: - Banners (AlertStore.announce)

/// Active, unsilenced instances that pass the filters: what banners are about. id → instance.
function currentlyActive(shown) {
    var out = {};
    shown.forEach(function (item) {
        item.instances.forEach(function (i) { if (isActive(i.state) && !i.silenced) out[i.id] = i; });
    });
    return out;
}

/// What to announce going from `previous` to `current` (both from currentlyActive):
/// { firing: [{ rule, instances }], resolved: [{ name, ruleUID, instances }] }.
function announcements(previous, current, shown, rules) {
    var firing = [];
    shown.forEach(function (item) {
        var fresh = item.instances.filter(function (i) { return current[i.id] && !previous[i.id]; });
        if (fresh.length) firing.push({ rule: item.rule, instances: fresh });
    });
    // The rules query only returns rules with firing/pending instances, so a rule that vanished from
    // the response has resolved entirely. One that's still there only resolved if the instance is no
    // longer active (rather than silenced or filtered).
    var live = {};
    rules.forEach(function (r) { live[r.uid] = r; });
    var gone = {};
    Object.keys(previous).forEach(function (id) {
        if (current[id]) return;
        var inst = previous[id];
        var rule = live[inst.ruleUID];
        if (rule && rule.instances.some(function (i) { return i.id === id && isActive(i.state); })) return;
        (gone[inst.ruleUID] = gone[inst.ruleUID] || []).push(inst);
    });
    var resolved = Object.keys(gone).map(function (uid) {
        var name = live[uid] ? live[uid].name : (gone[uid][0].labels.alertname || "Alert");
        return { name: name, ruleUID: uid, instances: gone[uid] };
    });
    return { firing: firing, resolved: resolved };
}

/// Banner title and text for a rule that started firing (SystemNotifier.postFiring).
function firingText(rule, instances) {
    var sev = Math.max.apply(null, instances.map(function (i) { return severity(i.labels.severity); }));
    var title = (sev === 3 ? "🔴 " : sev === 2 ? "🟠 " : "🔥 ") + rule.name;
    var sub = [rule.folder, instances.length > 1 ? instances.length + " instances" : null].filter(Boolean).join(" · ");
    var line = function (i) {
        var pairs = distinguishingLabels(i, rule.labels);
        return summaryOf(i.annotations) || (pairs.length ? labelText(pairs, " ") : stateTitles[i.state]);
    };
    var body = instances.slice(0, 4).map(line).join("\n");
    return { title: title, text: sub ? sub + "\n" + body : body };
}

// MARK: - Settings suggestions

/// [{ value, count }] most common first, skipping values already matched by `excluded`.
function topCounts(values, excluded, limit) {
    var counts = {};
    values.forEach(function (v) { counts[v] = (counts[v] || 0) + 1; });
    return Object.keys(counts).filter(function (v) { return !globAny(excluded || [], v); })
        .sort(function (a, b) { return counts[b] - counts[a] || (a < b ? -1 : 1); })
        .slice(0, limit || 8).map(function (v) { return { value: v, count: counts[v] }; });
}

/// Folders and `key=value` labels on current (non-normal) alerts, skipping per-instance noise.
function suggestionValues(rules) {
    var folders = [], labels = [];
    rules.forEach(function (r) {
        var active = r.instances.filter(function (i) { return i.state !== "normal"; });
        if (active.length) folders.push(r.folder);
        active.forEach(function (i) {
            Object.keys(i.labels).forEach(function (k) {
                var v = i.labels[k];
                if (k.indexOf("__") !== 0 && k !== "alertname" && k !== "grafana_folder" && v.length < 40) labels.push(k + "=" + v);
            });
        });
    });
    return { folders: folders, labels: labels };
}

/// [{ value, count }] of why rules are hidden, top 4.
function topReasons(hidden) {
    return topCounts(hidden.map(function (i) { return i.hiddenReason; }).filter(Boolean), [], 4);
}

// MARK: - Errors (GrafanaError)

var errorText = {
    notConfigured: ["Not set up", "Open Configure… → Account and enter your Grafana URL and a service account token."],
    unauthorized: ["Token rejected", "Grafana rejected the credentials. Check Configure… → Account."],
    forbidden: ["Access denied",
        "The token can't read alert rules. A Viewer service account is enough to read; silencing needs Editor."],
    http: ["Server error", "The server returned an error."],
    network: ["Can't reach Grafana", "The request failed."],
    decoding: ["Unexpected response", "Couldn't read the server's response."],
    keyring: ["Keyring problem", "Couldn't read the keyring."]
};

var errorIcon = {
    notConfigured: "user-identity", keyring: "object-locked", unauthorized: "object-locked", forbidden: "object-locked",
    network: "network-disconnect"
};

function apiError(kind, detail, status) {
    var e = new Error(detail || kind);
    e.kind = kind;
    e.detail = detail || "";
    e.status = status || 0;
    return e;
}

/// Grafana's `message` (or Alertmanager's `error`) from an error body.
function serverMessage(body) {
    try {
        var o = JSON.parse(body);
        return o && (nonEmpty(o.message) || nonEmpty(o.error)) || null;
    } catch (e) { return null; }
}

/// Maps an HTTP status (0 = no response) and body to an error, or null on success.
function errorForStatus(status, body) {
    if (status >= 200 && status < 300) return null;
    if (status === 0) return apiError("network", "");
    var message = serverMessage(body);
    if (status === 401) return apiError("unauthorized", message, status);
    if (status === 403) return apiError("forbidden", message, status);
    return apiError("http", message, status);
}

function errorInfo(err) {
    if (!err) return null;
    var kind = errorText[err.kind] ? err.kind : "network";
    var t = errorText[kind];
    var title = kind === "http" && err.status ? "Server error " + err.status : t[0];
    return { kind: kind, title: title, message: err.detail || t[1], icon: errorIcon[kind] || "dialog-warning" };
}

// MARK: - Auth helpers

/// Base64 of the UTF-8 bytes (Qt.btoa would mangle non-Latin-1 passwords).
function base64UTF8(s) {
    var bytes = unescape(encodeURIComponent(String(s)));
    var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var out = "";
    for (var i = 0; i < bytes.length; i += 3) {
        var a = bytes.charCodeAt(i), b = bytes.charCodeAt(i + 1), c = bytes.charCodeAt(i + 2);
        var n = (a << 16) | ((b || 0) << 8) | (c || 0);
        out += chars.charAt(n >> 18 & 63) + chars.charAt(n >> 12 & 63)
            + (i + 1 < bytes.length ? chars.charAt(n >> 6 & 63) : "=")
            + (i + 2 < bytes.length ? chars.charAt(n & 63) : "=");
    }
    return out;
}

function basicAuth(user, password) { return "Basic " + base64UTF8(user + ":" + password); }

/// The error for a `secret-tool lookup` that exited with `code`, or null if it ran (0) or found
/// nothing (1).
function keyringError(code, stderr) {
    if (code === 0 || code === 1) return null;
    if (code === 127) return apiError("keyring", "secret-tool isn't installed. It comes with libsecret (libsecret-tools on Debian/Ubuntu).");
    if (code === 124) return apiError("keyring", "The keyring didn't answer in time. Is it locked?");
    return apiError("keyring", nonEmpty(stderr) || "secret-tool failed (exit " + code + ").");
}

/// secret-tool prints the secret as stored; drop only the newline it may add.
function cleanSecret(s) { return String(s || "").replace(/\r?\n$/, ""); }

function tokenAccount(base) { return "token:" + base; }
function passwordAccount(base) { return "password:" + base; }

/// Single-quotes a value for /bin/sh.
function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

// MARK: - Formatting (Fmt)

var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function ago(t, now, short) {
    var s = Math.max(0, (now - t) / 1000);
    if (s < 60) return short ? "now" : "just now";
    var m = Math.floor(s / 60), v;
    if (m < 60) v = m + "m";
    else if (m < 1440) v = Math.floor(m / 60) + "h";
    else if (m < 1440 * 30) v = Math.floor(m / 1440) + "d";
    else { var d = new Date(t); return months[d.getMonth()] + " " + d.getDate(); }
    return short ? v : v + " ago";
}

function countText(n) { return n > 99 ? "99+" : String(n); }

function duration(seconds) {
    var h = Math.floor(seconds / 3600);
    if (h >= 168 && h % 168 === 0) return h / 168 + " week" + (h === 168 ? "" : "s");
    if (h >= 24 && h % 24 === 0) return h / 24 + " day" + (h === 24 ? "" : "s");
    return h + " hour" + (h === 1 ? "" : "s");
}

function isoSeconds(ms) { return new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(".000Z", "Z"); }

/// "critical" | "warning" | "info" tint for a severity number (unknown counts as critical).
function severityTint(sev) { return sev === 2 ? "warning" : sev === 1 ? "info" : "critical"; }
