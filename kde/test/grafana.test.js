// Run: node kde/test/grafana.test.js
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert");
const src = fs.readFileSync(path.join(__dirname, "../package/contents/code/grafana.js"), "utf8")
    .replace(/^\.pragma library.*$/m, "");
const G = {};
vm.runInNewContext(src + "\nObject.assign(G, this);", { G });

const now = Date.parse("2026-11-21T12:00:00Z");
let pass = 0;
// Objects come from another VM realm, so compare by value.
const eq = (a, b) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b));
function test(name, fn) {
    try { fn(); pass++; } catch (e) { console.error("FAIL " + name); throw e; }
}

const alert = (over = {}) => Object.assign({
    labels: { alertname: "High CPU", grafana_folder: "Infra", host: "web-01", severity: "warning",
              __alert_rule_uid__: "cpu" },
    annotations: { summary: "CPU at 97%" },
    state: "Alerting", activeAt: "2026-11-21T11:00:00.123456789Z", value: "97",
}, over);

const rule = (over = {}) => Object.assign({
    uid: "cpu", name: "High CPU", state: "firing", health: "ok", type: "alerting",
    labels: {}, annotations: { runbook_url: "https://wiki/cpu", __dashboardUid__: "abc", __panelId__: "4" },
    alerts: [alert(), alert({ labels: { alertname: "High CPU", host: "web-02", severity: "warning" }, state: "Pending",
                              activeAt: "0001-01-01T00:00:00Z" })],
}, over);

const response = (groups) => JSON.stringify({ status: "success", data: { groups } });
const group = (rules, over = {}) => Object.assign({ name: "hosts", file: "Infra", folderUid: "f1", rules }, over);

const config = (over = {}) => G.filtersFromConfig(Object.assign({
    filterShowPending: false, filterHideSilenced: true, filterMinSeverity: 0, filterIncludeFolders: "",
    filterExcludeFolders: "", filterExcludeGroups: "", filterExcludeRules: "", filterHiddenRuleUIDs: "",
    filterIncludeLabels: "", filterExcludeLabels: "",
}, over));

test("instance and rule states", () => {
    assert.strictEqual(G.instanceState("Alerting"), "firing");
    assert.strictEqual(G.instanceState("Alerting (NoData)"), "firing");
    assert.strictEqual(G.instanceState("NoData"), "firing");
    assert.strictEqual(G.instanceState("Error"), "firing");
    assert.strictEqual(G.instanceState("Pending"), "pending");
    assert.strictEqual(G.instanceState("Recovering"), "recovering");
    assert.strictEqual(G.instanceState("Normal (MissingSeries)"), "normal");
    assert.strictEqual(G.stateReason("Alerting (Error)"), "Error");
    assert.strictEqual(G.stateReason("nodata"), "NoData");
    assert.strictEqual(G.stateReason("Alerting"), null);
    assert.strictEqual(G.ruleState("inactive"), "normal");
    assert.strictEqual(G.ruleState("Firing"), "firing");
});

test("severity", () => {
    assert.strictEqual(G.severity("CRIT"), 3);
    assert.strictEqual(G.severity("p3"), 2);
    assert.strictEqual(G.severity("low"), 1);
    assert.strictEqual(G.severity(""), 0);
    assert.strictEqual(G.severity(undefined), 0);
});

test("parse rules", () => {
    const rules = G.parseRules(response([group([rule(), rule({ uid: "rec", type: "recording" }), rule({ uid: undefined })])]));
    assert.strictEqual(rules.length, 1);
    const r = rules[0];
    assert.strictEqual(r.folder, "Infra");
    assert.strictEqual(r.group, "hosts");
    assert.strictEqual(r.folderUID, "f1");
    assert.strictEqual(r.instances.length, 2);
    const [a, b] = r.instances;
    assert.strictEqual(a.state, "firing");
    assert.strictEqual(a.activeAt, Date.parse("2026-11-21T11:00:00.123Z"));
    assert.strictEqual(a.id, "cpu|alertname=High CPU,grafana_folder=Infra,host=web-01,severity=warning");
    assert.strictEqual(b.activeAt, null);   // Go's zero time
    assert.strictEqual(b.state, "pending");
    eq(G.distinguishingLabels(a, G.commonLabels(r)), [["grafana_folder", "Infra"], ["host", "web-01"]].filter(p => p[0] !== "grafana_folder"));
    assert.throws(() => G.parseRules("<html>login</html>"), e => e.kind === "decoding" && /web page/.test(e.detail));
    assert.throws(() => G.parseRules("{}"), e => e.kind === "decoding");
});

test("date parsing", () => {
    assert.strictEqual(G.parseDate("2026-11-20T03:59:00Z"), Date.parse("2026-11-20T03:59:00Z"));
    assert.strictEqual(G.parseDate("2026-11-20T03:59:00.5+0100"), Date.parse("2026-11-20T02:59:00.5Z"));
    assert.strictEqual(G.parseDate("2026-11-20T03:59:00.123456789-08:00"), Date.parse("2026-11-20T11:59:00.123Z"));
    assert.strictEqual(G.parseDate("nope"), null);
    assert.strictEqual(G.parseDate(null), null);
});

test("state set step-down", () => {
    const err = G.errorForStatus(400, '{"message":"unknown state \'recovering\'"}');
    assert.ok(G.shouldStepDown(err, 0));
    assert.ok(G.shouldStepDown(err, 1));
    assert.ok(!G.shouldStepDown(err, 2));
    assert.ok(!G.shouldStepDown(G.errorForStatus(400, '{"message":"bad"}'), 0));
    assert.ok(!G.shouldStepDown(G.errorForStatus(500, '{"message":"state"}'), 0));
});

test("silences", () => {
    const ids = G.parseSuppressed(JSON.stringify([
        { labels: { __alert_rule_uid__: "cpu", host: "web-01", __name__: "x" }, status: { state: "suppressed" } },
        { labels: { __alert_rule_uid__: "cpu", host: "web-02" }, status: { state: "active" } },
        { labels: { host: "nouid" }, status: { state: "suppressed" } },
    ]));
    eq(Object.keys(ids), ["cpu|host=web-01"]);
    const body = G.silenceBody("cpu", { host: "web-01", __alert_rule_uid__: "cpu", env: "prod" }, 3600, "c", now);
    eq(body.matchers.map(m => m.name + "=" + m.value), ["__alert_rule_uid__=cpu", "env=prod", "host=web-01"]);
    assert.strictEqual(body.startsAt, "2026-11-21T12:00:00Z");
    assert.strictEqual(body.endsAt, "2026-11-21T13:00:00Z");
    assert.strictEqual(G.silenceBody("cpu", null, 60, "", now).matchers.length, 1);
});

test("server normalization", () => {
    assert.strictEqual(G.normalizeServer(" grafana.example.com/ "), "https://grafana.example.com");
    assert.strictEqual(G.normalizeServer("http://localhost:3000"), "http://localhost:3000");
    assert.strictEqual(G.normalizeServer("https://example.com/grafana/alerting/list?search=x"), "https://example.com/grafana");
    assert.strictEqual(G.normalizeServer("https://g.example/d/abc/my-dash?orgId=1"), "https://g.example");
    assert.strictEqual(G.normalizeServer("ftp://x"), null);
    assert.strictEqual(G.normalizeServer(""), null);
});

test("links", () => {
    const base = "https://g.example/grafana";
    const r = G.parseRules(response([group([rule()])]))[0];
    assert.strictEqual(G.ruleURL(base, "cpu"), "https://g.example/grafana/alerting/grafana/cpu/view");
    assert.strictEqual(G.firingListURL(base), "https://g.example/grafana/alerting/list?search=state%3Afiring");
    assert.strictEqual(G.silencesURL(base), "https://g.example/grafana/alerting/silences");
    assert.strictEqual(G.dashboardURL(base, r), "https://g.example/grafana/d/abc?viewPanel=4");
    assert.strictEqual(G.runbookURL(r, null), "https://wiki/cpu");
    assert.strictEqual(G.runbookURL(Object.assign({}, r, { annotations: { runbook_url: "javascript:x" } }), null), null);
    assert.strictEqual(G.ruleURL("", "cpu"), null);
});

test("glob and matchers", () => {
    assert.ok(G.globMatches("Staging*", "staging-eu"));
    assert.ok(!G.globMatches("Staging", "Staging-eu"));
    assert.ok(G.globMatches("a?c", "abc"));
    assert.strictEqual(G.globLiteral("a,b*c?"), "a?b?c?");
    assert.ok(G.globMatches(G.globLiteral("Infra, prod"), "Infra, prod"));
    const labels = { host: "build-01", env: "dev-2" };
    const m = s => G.matcherMatches(G.parseMatcher(s), labels);
    assert.ok(m("host=build-01"));
    assert.ok(m("env=dev*"));
    assert.ok(!m("env!=dev*"));
    assert.ok(m("team="));          // missing label matches empty
    assert.ok(m("team!=infra"));
    assert.ok(m("BUILD-01"));       // bare value, any label, case-insensitive
    assert.strictEqual(G.parseMatcher("=x"), null);
    eq(G.parseMatcher("expr=a!=b"), { key: "expr", value: "a!=b", negated: false });
    eq(G.parseMatcher("a!=b=c"), { key: "a", value: "b=c", negated: true });
    assert.strictEqual(G.labelLiteral("msg=disk a,b*"), "msg=disk a?b?");
    assert.ok(G.matcherMatches(G.parseMatcher(G.labelLiteral("msg=disk a,b")), { msg: "disk a,b" }));
    assert.strictEqual(G.matcherText(G.parseMatcher(" env != dev ")), "env!=dev");
    assert.strictEqual(G.appendPattern("a, B", "b"), "a, B");
    assert.strictEqual(G.appendPattern("", "x"), "x");
});

test("rule filters", () => {
    const r = G.parseRules(response([group([rule()])]))[0];
    assert.strictEqual(G.ruleHiddenReason(config(), r), null);
    assert.strictEqual(G.ruleHiddenReason(config({ filterHiddenRuleUIDs: "cpu" }), r), "Hidden rule");
    assert.strictEqual(G.ruleHiddenReason(config({ filterIncludeFolders: "Apps" }), r), "Folder Infra");
    assert.strictEqual(G.ruleHiddenReason(config({ filterExcludeFolders: "inf*" }), r), "Folder Infra");
    assert.strictEqual(G.ruleHiddenReason(config({ filterExcludeGroups: "Infra/hosts" }), r), "Group hosts");
    assert.strictEqual(G.ruleHiddenReason(config({ filterExcludeGroups: "Other/hosts" }), r), null);
    assert.strictEqual(G.ruleHiddenReason(config({ filterExcludeRules: "cpu" }), r), "Rule name");
});

test("instance filters", () => {
    const [a, b] = G.parseRules(response([group([rule()])]))[0].instances;
    assert.strictEqual(G.instanceHiddenReason(config(), a), null);
    assert.strictEqual(G.instanceHiddenReason(config(), b), "Pending");
    assert.strictEqual(G.instanceHiddenReason(config({ filterShowPending: true }), b), null);
    const silenced = Object.assign({}, a, { silenced: true });
    assert.strictEqual(G.instanceHiddenReason(config(), silenced), "Silenced");
    assert.strictEqual(G.instanceHiddenReason(config({ filterHideSilenced: false }), silenced), null);
    assert.strictEqual(G.instanceHiddenReason(config({ filterMinSeverity: 3 }), a), "Severity warning");
    const unlabeled = Object.assign({}, a, { labels: { host: "x" } });
    assert.strictEqual(G.instanceHiddenReason(config({ filterMinSeverity: 3 }), unlabeled), null);
    assert.strictEqual(G.instanceHiddenReason(config({ filterIncludeLabels: "team=infra" }), a), "Labels");
    assert.strictEqual(G.instanceHiddenReason(config({ filterExcludeLabels: "host=web-*" }), a), "host=web-*");
});

test("partition, counts and order", () => {
    const rules = G.parseRules(response([
        group([rule()]),
        group([rule({ uid: "disk", name: "Disk full", alerts: [alert({ labels: { severity: "critical", host: "db" },
                                                                         activeAt: "2026-11-21T09:00:00Z" })] })]),
        group([rule({ uid: "q", name: "Queue", alerts: [alert({ labels: { team: "x" }, state: "Pending" })] })]),
        group([rule({ uid: "mute", name: "Muted", alerts: [alert({ labels: { __alert_rule_uid__: "mute", host: "m" } })] })]),
    ]));
    const silenced = G.applySilences(rules, { "mute|host=m": true });
    eq(Object.keys(G.silencedIDs(silenced)), ["mute|host=m"]);
    let p = G.partition(silenced, config());
    eq(p.shown.map(i => i.id), ["disk", "cpu"]);         // critical before warning
    eq(p.hidden.map(i => [i.id, i.hiddenReason]), [["mute", "Silenced"], ["q", "Pending"]]);
    assert.strictEqual(p.shown[1].hiddenInstances, 1);    // cpu's pending instance
    assert.strictEqual(G.badgeCount(p.shown, "rules"), 2);
    assert.strictEqual(G.worstSeverity(p.shown), 3);
    assert.strictEqual(G.pendingCount(p.shown), 0);

    p = G.partition(silenced, config({ filterShowPending: true, filterHideSilenced: false }));
    eq(p.shown.map(i => i.id), ["disk", "cpu", "mute", "q"]);   // silenced after unsilenced; pending last
    assert.strictEqual(G.badgeCount(p.shown, "rules"), 2);       // silenced and pending never count
    assert.strictEqual(G.badgeCount(p.shown, "instances"), 2);
    assert.strictEqual(G.pendingCount(p.shown), 1);
    assert.ok(p.shown[2].allSilenced);
    const cpu = p.shown[1];
    eq(cpu.instances.map(i => i.state), ["firing", "pending"]);
    assert.strictEqual(cpu.since, Date.parse("2026-11-21T11:00:00.123Z"));
    assert.strictEqual(cpu.summary, "CPU at 97%");
    assert.strictEqual(cpu.severityLabel, "warning");

    // Unlabeled alerts count as critical for the badge color.
    const plain = G.partition(G.parseRules(response([group([rule({ alerts: [alert({ labels: { a: "b" } })] })])])), config());
    assert.strictEqual(G.worstSeverity(plain.shown), 3);
    assert.strictEqual(G.worstSeverity([]), null);
});

test("announcements", () => {
    const rules1 = G.parseRules(response([group([rule()])]));
    const p1 = G.partition(rules1, config());
    const first = G.currentlyActive(p1.shown);
    assert.strictEqual(Object.keys(first).length, 1);

    // A second host starts firing; the first is still firing.
    const rules2 = G.parseRules(response([group([rule({ alerts: [alert(), alert({ labels: { host: "web-03", severity: "critical" } })] })])]));
    const p2 = G.partition(rules2, config());
    const second = G.currentlyActive(p2.shown);
    let a = G.announcements(first, second, p2.shown, rules2);
    eq(a.firing.map(f => f.instances.map(i => i.labels.host)), [["web-03"]]);
    eq(a.resolved, []);
    const text = G.firingText(a.firing[0].rule, a.firing[0].instances);
    assert.strictEqual(text.title, "🔴 High CPU");
    assert.strictEqual(text.text, "Infra\nCPU at 97%");

    // Rule vanished from the response: resolved.
    a = G.announcements(second, {}, [], []);
    eq(a.resolved.map(r => [r.name, r.instances.length]), [["High CPU", 2]]);

    // Still firing but now silenced: not resolved.
    const silenced = G.applySilences(rules2, G.parseSuppressed(JSON.stringify([
        { labels: { __alert_rule_uid__: "cpu", alertname: "High CPU", host: "web-03", severity: "critical" },
          status: { state: "suppressed" } }])));
    const p3 = G.partition(silenced, config());
    a = G.announcements(second, G.currentlyActive(p3.shown), p3.shown, silenced);
    eq(a.resolved, []);
    eq(a.firing, []);
});

test("suggestions", () => {
    const rules = G.parseRules(response([group([rule()]), group([rule({ uid: "b" })], { file: "Apps" }), group([rule({ uid: "c" })])]));
    const s = G.suggestionValues(rules);
    eq(G.topCounts(s.folders, [], 8), [{ value: "Infra", count: 2 }, { value: "Apps", count: 1 }]);
    eq(G.topCounts(s.folders, ["inf*"], 8), [{ value: "Apps", count: 1 }]);
    assert.ok(s.labels.indexOf("host=web-01") >= 0);
    assert.ok(!s.labels.some(l => l.indexOf("alertname=") === 0 || l.indexOf("__") === 0));
});

test("errors", () => {
    assert.strictEqual(G.errorForStatus(204, ""), null);
    eq(G.errorInfo(G.errorForStatus(401, '{"message":"invalid API key"}')),
       { kind: "unauthorized", title: "Token rejected", message: "invalid API key", icon: "object-locked" });
    assert.strictEqual(G.errorInfo(G.errorForStatus(502, "<html>")).title, "Server error 502");
    assert.strictEqual(G.errorInfo(G.errorForStatus(400, '{"error":"bad matcher"}')).message, "bad matcher");
    assert.strictEqual(G.errorInfo(G.errorForStatus(0, "")).kind, "network");
    assert.strictEqual(G.errorInfo(G.apiError("notConfigured")).title, "Not set up");
});

test("auth helpers", () => {
    assert.strictEqual(G.basicAuth("admin", "admin"), "Basic YWRtaW46YWRtaW4=");
    assert.strictEqual(G.base64UTF8("pässwörd✓"), Buffer.from("pässwörd✓").toString("base64"));
    assert.strictEqual(G.base64UTF8("ab"), "YWI=");
    assert.strictEqual(G.base64UTF8("a"), "YQ==");
    assert.strictEqual(G.cleanSecret("  secret \n"), "  secret ");
    assert.strictEqual(G.tokenAccount("https://g"), "token:https://g");
    assert.strictEqual(G.shellQuote("it's"), "'it'\\''s'");
});

test("formatting", () => {
    assert.strictEqual(G.ago(now - 30e3, now), "just now");
    assert.strictEqual(G.ago(now - 125e3, now, true), "2m");
    assert.strictEqual(G.ago(now - 5 * 3600e3, now), "5h ago");
    assert.strictEqual(G.ago(Date.parse("2026-09-03T12:00:00"), now), "Sep 3");
    assert.strictEqual(G.countText(120), "99+");
    assert.strictEqual(G.duration(3600), "1 hour");
    assert.strictEqual(G.duration(4 * 3600), "4 hours");
    assert.strictEqual(G.duration(86400), "1 day");
    assert.strictEqual(G.duration(7 * 86400), "1 week");
    assert.strictEqual(G.severityTint(2), "warning");
    assert.strictEqual(G.severityTint(0), "critical");
});

test("severity label comes from the worst instance", () => {
    const r = G.parseRules(response([group([rule({ alerts: [
        alert({ labels: { host: "a", severity: "warning" } }), alert({ labels: { host: "b", severity: "critical" } })] })])]));
    const item = G.partition(r, config()).shown[0];
    assert.strictEqual(item.instances[0].labels.host, "a");
    assert.strictEqual(item.severityLabel, "critical");
    assert.strictEqual(item.severity, 3);
});

test("keyring errors", () => {
    assert.strictEqual(G.keyringError(0, ""), null);
    assert.strictEqual(G.keyringError(1, ""), null);
    assert.strictEqual(G.keyringError(127, "").kind, "keyring");
    assert.ok(/locked/.test(G.keyringError(124, "").detail));
    assert.strictEqual(G.keyringError(2, "boom\n").detail, "boom");
    assert.strictEqual(G.errorInfo(G.keyringError(127, "")).title, "Keyring problem");
});

test("state set cache expires", () => {
    assert.strictEqual(G.stateSetIndex(undefined, now), 0);
    assert.strictEqual(G.stateSetIndex({ index: 2, at: now - 60e3 }, now), 2);
    assert.strictEqual(G.stateSetIndex({ index: 2, at: now - 61 * 60e3 }, now), 0);
});

console.log(`${pass} tests passed`);
