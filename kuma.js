// kuma.js: drives Uptime Kuma 2.x from inside its own container (UPTIME.md; lib.sh kuma_run).
// Kuma 2.x has no REST API for writes: the web UI talks socket.io, and so does this script,
// through the socket.io-client that ships in the Kuma image (/app/node_modules) [verify].
// It talks to http://127.0.0.1:3001, so it works before DNS and HTTPS do.
//
// Input: one JSON plan on stdin (it carries the admin password, so it never goes on a command line):
//   {"action":"init","user":"admin","password":"..."}
//   {"action":"sync","user":"admin","password":"...","monitors":[{"name":"shop","url":"https://shop.example.com"}],
//    "page":{"slug":"acme","title":"Acme","description":"Status of Acme"},"group":"Acme"}
//   {"action":"domain","user":"admin","password":"...","slug":"acme","add":["status.acme.com"],"remove":[]}
// Output: one JSON line, {"ok":true,...} with exit 0 or {"ok":false,"msg":"..."} with exit 1. The
// password is never printed. Gives up after 90 seconds plus 20 per monitor to add, at most 300.
//
// The domain action answers {"ok":true,"page":"/status/acme","domains":[...],"added":[...],
// "removed":[...],"absent":[...],"changed":true|false} (UPTIME.md step 9).
//
// Never destructive: it never deletes a monitor, a status page or a group. A monitor is matched by
// its URL (case and a trailing slash ignored), so a renamed one is kept, and a status page keeps
// every group and monitor added by hand; ours are added to the group named in the plan. The
// domain action never creates a page, keeps every other domain of the page, and refuses a host
// that another page has (Kuma would move it to this page without a word).
"use strict";

const BASE = "http://127.0.0.1:3001";
const HARD_TIMEOUT_MS = 90000;

// hardTimeoutMs(toAdd) -> 90 s plus 20 s per monitor to add (each add waits up to 20 s), at most 300 s.
function hardTimeoutMs(toAdd) { return Math.min(HARD_TIMEOUT_MS + 20000 * Math.max(0, toAdd | 0), 300000); }
const SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
// A host name as lib.sh's cf_valid_name takes it: lower case, at least two labels, at most 253 characters.
const HOST_RE = /^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/;

// What the Kuma 2.x UI sends for a new HTTP monitor (EditMonitor.vue), with our interval, one
// retry after 30 s and a 30 s timeout [verify].
const MONITOR_DEFAULTS = {
  type: "http", method: "GET", interval: 60, retryInterval: 30, resendInterval: 0, maxretries: 1,
  timeout: 30, notificationIDList: {}, ignoreTls: false, upsideDown: false, expiryNotification: false,
  maxredirects: 10, accepted_statuscodes: ["200-299"], dns_resolve_type: "A",
  dns_resolve_server: "1.1.1.1", proxyId: null, authMethod: null, httpBodyEncoding: "json",
  cacheBust: false, parent: null, kafkaProducerBrokers: [], kafkaProducerSaslOptions: { mechanism: "None" },
  conditions: [], rabbitmqNodes: [],
};

function fail(msg) { const e = new Error(msg); e.kuma = true; return e; }

function normUrl(u) { return String(u || "").trim().toLowerCase().replace(/\/+$/, ""); }

function nonEmpty(v) { return typeof v === "string" && v.length > 0; }

// normHost(h) -> h trimmed, lower case, without a trailing dot. Kuma matches the host exactly and
// stores what it gets, so every host is normalised here.
function normHost(h) { return String(h == null ? "" : h).trim().toLowerCase().replace(/\.$/, ""); }

// validatePlan(plan) -> the plan, or throws with what is wrong (never echoing the password).
function validatePlan(p) {
  if (!p || typeof p !== "object" || Array.isArray(p)) throw fail("the plan is not a JSON object");
  if (p.action !== "init" && p.action !== "sync" && p.action !== "domain") throw fail("unknown action: " + JSON.stringify(p.action));
  if (!nonEmpty(p.user)) throw fail("the plan has no user");
  if (!nonEmpty(p.password)) throw fail("the plan has no password");
  if (p.action === "sync") {
    const pg = p.page || {};
    if (!nonEmpty(pg.slug) || !SLUG_RE.test(pg.slug)) throw fail("not a status page slug: " + JSON.stringify(pg.slug));
    if (!nonEmpty(pg.title)) throw fail("the status page has no title");
    if (!nonEmpty(p.group)) throw fail("the plan has no group name");
    if (!Array.isArray(p.monitors)) throw fail("the plan has no monitor list");
    for (const m of p.monitors) {
      if (!m || !nonEmpty(m.name) || !nonEmpty(m.url) || !/^https?:\/\/[^\s/]+/.test(m.url)) {
        throw fail("not a monitor {name, url}: " + JSON.stringify(m));
      }
    }
  }
  if (p.action === "domain") {
    if (!nonEmpty(p.slug) || !SLUG_RE.test(p.slug)) throw fail("not a status page slug: " + JSON.stringify(p.slug));
    for (const k of ["add", "remove"]) {
      if (p[k] === undefined) p[k] = [];
      if (!Array.isArray(p[k])) throw fail("the plan's " + k + " is not a list");
      p[k] = p[k].map((h) => {
        const n = typeof h === "string" ? normHost(h) : "";
        if (!HOST_RE.test(n)) throw fail("not a host name: " + JSON.stringify(h) + " (the host only, like status.acme.com)");
        return n;
      });
    }
    if (p.add.length + p.remove.length === 0) throw fail("the plan adds and removes no domain");
    const both = p.add.filter((h) => p.remove.includes(h));
    if (both.length) throw fail("a host to add and to remove at once: " + both.join(", "));
  }
  return p;
}

// planDomains(existing, add, remove, others) -> {list, added, removed, absent}: the page's domains
// (existing) in their order, the hosts of add appended once, the hosts of remove dropped when the
// page has them (absent: the ones it does not have). others maps every host of another page to
// its slug: a host to add that is there throws, because Kuma would take it from that page.
function planDomains(existing, add, remove, others) {
  const taken = Object.keys(others || {}).filter((h) => (add || []).includes(h));
  if (taken.length) {
    throw fail(taken.map((h) => h + " is on status page " + others[h]).join("; ") + "; nothing changed");
  }
  const list = [], seen = new Set();
  for (const d of existing || []) {
    const n = normHost(d);
    if (n === "" || seen.has(n)) continue;
    seen.add(n); list.push(d);
  }
  const added = [], removed = [], absent = [];
  for (const h of add || []) {
    if (!seen.has(h)) { seen.add(h); list.push(h); added.push(h); }
  }
  for (const h of remove || []) {
    if (seen.has(h)) { seen.delete(h); removed.push(h); } else absent.push(h);
  }
  return { list: list.filter((d) => !removed.includes(normHost(d))), added, removed, absent };
}

// planMonitors(monitorList, wanted) -> {add: [{name, url}], kept: [{name, url, id}]}. monitorList
// is Kuma's (an object keyed by id, or an array); a wanted monitor whose URL a monitor already has
// is kept as it is, whatever its name. Wanted URLs twice count once.
function planMonitors(monitorList, wanted) {
  const list = Array.isArray(monitorList) ? monitorList : Object.values(monitorList || {});
  const byUrl = new Map();
  for (const m of list) {
    if (m && m.url && m.id != null && !byUrl.has(normUrl(m.url))) byUrl.set(normUrl(m.url), m);
  }
  const seen = new Set(), add = [], kept = [];
  for (const w of wanted) {
    const k = normUrl(w.url);
    if (seen.has(k)) continue;
    seen.add(k);
    const m = byUrl.get(k);
    if (m) kept.push({ name: w.name, url: w.url, id: m.id }); else add.push({ name: w.name, url: w.url });
  }
  return { add, kept };
}

// mergeGroups(publicGroupList, groupName, ids) -> {groups, placed}: every existing group with its
// monitors, in its order, and the ids not on the page yet appended to the group named groupName
// (a new group at the end when there is none). saveStatusPage deletes any group missing from the
// list it gets, so nothing is ever left out.
function mergeGroups(publicGroupList, groupName, ids) {
  const groups = (publicGroupList || []).map((g) => {
    const out = { name: g.name, monitorList: (g.monitorList || []).map((m) => {
      const r = { id: m.id };
      if (m.sendUrl !== undefined) r.sendUrl = m.sendUrl;
      // saveStatusPage writes url to the monitor's custom link: dropping it would reset one set by hand
      if (m.url !== undefined) r.url = m.url;
      return r;
    }) };
    if (g.id != null) out.id = g.id;
    if (g.weight != null) out.weight = g.weight;
    return out;
  });
  const onPage = new Set();
  for (const g of groups) for (const m of g.monitorList) onPage.add(String(m.id));
  const missing = [];
  for (const id of ids) {
    if (!onPage.has(String(id))) { onPage.add(String(id)); missing.push(id); }
  }
  if (missing.length) {
    let g = groups.find((x) => x.name === groupName);
    if (!g) { g = { name: groupName, weight: groups.length + 1, monitorList: [] }; groups.push(g); }
    for (const id of missing) g.monitorList.push({ id });
  }
  return { groups, placed: missing.length };
}

// pageConfig(existing, page) -> the config for saveStatusPage: what the page has (domains, CSS,
// footer, analytics, icon) with our title, description and display settings.
function pageConfig(existing, page) {
  return Object.assign({}, existing || {}, {
    slug: page.slug, title: page.title, description: page.description || "",
    theme: "auto", showTags: false, showPoweredBy: false, showCertificateExpiry: true,
    autoRefreshInterval: 300, domainNameList: (existing && existing.domainNameList) || [],
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// emitAck(socket, event, ...args) -> the server's callback answer, or throws after 20 s.
function emitAck(socket, event, ...args) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(fail("Kuma did not answer " + event + " within 20 s")), 20000);
    socket.emit(event, ...args, (res) => { clearTimeout(t); resolve(res); });
  });
}

// connect(deps, ms) -> a connected socket, retrying until ms have passed (Kuma may still be starting).
async function connect(deps, ms) {
  const end = Date.now() + ms;
  let last = "no answer";
  for (;;) {
    const s = deps.io(BASE, { transports: ["websocket"], reconnection: false, timeout: 5000 });
    try {
      await new Promise((resolve, reject) => {
        s.once("connect", resolve);
        s.once("connect_error", (e) => reject(e));
      });
      return s;
    } catch (e) {
      last = (e && e.message) || String(e);
      try { s.close(); } catch (_) { /* already closed */ }
    }
    if (Date.now() >= end) throw fail("could not connect to Kuma at " + BASE + ": " + last);
    await sleep(deps.retryMs == null ? 2000 : deps.retryMs);
  }
}

// http(deps, method, path, body) -> {status, json} (json null when the answer is not JSON);
// throws when nothing answers.
async function http(deps, method, path, body) {
  const opts = { method, headers: { Accept: "application/json" } };
  if (body !== undefined) { opts.body = JSON.stringify(body); opts.headers["Content-Type"] = "application/json"; }
  const r = await deps.fetch(BASE + path, opts);
  const text = await r.text();
  let json = null;
  try { json = JSON.parse(text); } catch (_) { json = null; }
  return { status: r.status, json };
}

function kumaMsg(r) { return (r && (r.msg || r.message)) || "no message"; }

async function login(s, plan, justCreated) {
  const r = await emitAck(s, "login", { username: plan.user, password: plan.password, token: "" });
  if (r && r.tokenRequired) throw fail("2FA is on for the Kuma admin; this script cannot log in with it. Turn 2FA off in Kuma (Settings -> Security) or keep the monitors by hand (UPTIME.md step 8)");
  if (!r || r.ok !== true) {
    if (justCreated) throw fail("login failed right after creating the admin: " + kumaMsg(r));
    throw fail("admin exists and kuma.env does not open it (" + kumaMsg(r) + ")");
  }
}

// init: the database type page (SQLite), then the admin from the plan. A second run changes nothing.
async function init(plan, deps) {
  let dbSetup = false, info = null;
  const end = Date.now() + 60000;
  for (;;) {   // the first answer tells which server runs: the database setup one answers JSON
    try { info = (await http(deps, "GET", "/setup-database-info")).json; break; } catch (e) {
      if (Date.now() >= end) throw fail("Kuma does not answer on " + BASE + ": " + ((e && e.message) || e));
      await sleep(deps.retryMs == null ? 2000 : deps.retryMs);
    }
  }
  if (info && info.needSetup === true) {
    const r = await http(deps, "POST", "/setup-database", { dbConfig: { type: "sqlite" } });
    if (!r.json || r.json.ok !== true) throw fail("Kuma refused the database setup (HTTP " + r.status + "): " + kumaMsg(r.json));
    dbSetup = true;
  }
  const s = await connect(deps, 60000);
  try {
    const need = await emitAck(s, "needSetup");
    let created = false;
    if (need === true) {
      const r = await emitAck(s, "setup", plan.user, plan.password);
      if (!r || r.ok !== true) throw fail("Kuma did not create the admin: " + kumaMsg(r));
      created = true;
    }
    await login(s, plan, created);
    return { ok: true, db_setup: dbSetup, admin_created: created };
  } finally { s.close(); }
}

// publicGroups(deps, slug) -> the groups of the page from its public JSON, or null when they
// cannot be read. saveStatusPage deletes every group it does not get, so a save needs them all.
async function publicGroups(deps, slug) {
  const pub = await http(deps, "GET", "/api/status-page/" + slug).catch(() => ({ json: null }));
  return pub.json && Array.isArray(pub.json.publicGroupList) ? pub.json.publicGroupList : null;
}

// waitFor(get, ms, what) -> resolves once get() is not null, throws after ms.
async function waitFor(get, ms, what) {
  const end = Date.now() + ms;
  while (get() === null) {
    if (Date.now() >= end) throw fail(what);
    await sleep(50);
  }
}

// sync: one monitor per wanted URL, the status page, our monitors on it. Idempotent.
async function sync(plan, deps) {
  const s = await connect(deps, 20000);
  let monitorList = null;
  s.on("monitorList", (l) => { monitorList = l; });   // pushed by Kuma right after the login
  try {
    await login(s, plan, false);
    await waitFor(() => monitorList, deps.listMs == null ? 15000 : deps.listMs, "Kuma sent no monitor list within 15 s of the login");
    const { add, kept } = planMonitors(monitorList, plan.monitors);
    if (deps.onAdds) deps.onAdds(add.length);   // main() stretches the hard timeout
    const ids = kept.map((k) => k.id), added = [];
    for (const m of add) {
      const r = await emitAck(s, "add", Object.assign({}, MONITOR_DEFAULTS, { name: m.name, url: m.url }));
      if (!r || r.ok !== true) throw fail("Kuma refused the monitor " + m.name + ": " + kumaMsg(r) + (added.length ? " (added before it: " + added.join(", ") + ")" : ""));
      ids.push(r.monitorID); added.push(m.name);
    }
    const slug = plan.page.slug;
    let page = await emitAck(s, "getStatusPage", slug), created = false;
    if (!page || page.ok !== true) {
      const r = await emitAck(s, "addStatusPage", plan.page.title, slug);
      if (!r || r.ok !== true) throw fail("Kuma refused the status page " + slug + ": " + kumaMsg(r));
      page = await emitAck(s, "getStatusPage", slug);
      if (!page || page.ok !== true) throw fail("the new status page " + slug + " cannot be read: " + kumaMsg(page));
      created = true;
    }
    // The groups as they are now (public JSON); without them a save would delete groups, so stop.
    // Kuma caches that JSON for 5 minutes, a 404 too, and addStatusPage does not clear it: a page
    // made by this run has no groups yet, so it is not read.
    let current = [];
    if (!created) {
      current = await publicGroups(deps, slug);
      if (current === null) {
        throw fail("could not read the groups of status page " + slug + "; the page was not saved" + (added.length ? " (monitors added: " + added.join(", ") + ")" : ""));
      }
    }
    const { groups } = mergeGroups(current, plan.group, ids);
    const config = pageConfig(page.config, plan.page);
    const r = await emitAck(s, "saveStatusPage", slug, config, (page.config && page.config.icon) || "/icon.svg", groups);
    if (!r || r.ok !== true) throw fail("Kuma did not save the status page " + slug + ": " + kumaMsg(r));
    return { ok: true, added, kept: kept.map((k) => k.name), page: "/status/" + slug, groups: groups.length };
  } finally { s.close(); }
}

// domain: the hosts of plan.add onto the page's domainNameList, the hosts of plan.remove off it
// (UPTIME.md step 9). Kuma serves the page at / on each of them. Never creates a page, keeps the
// page's other domains, groups, icon and settings, and refuses a host another page has (Kuma's
// save would move it silently). Nothing to change: nothing is saved.
async function domain(plan, deps) {
  const s = await connect(deps, 20000);
  let pageList = null;
  s.on("statusPageList", (l) => { pageList = l; });   // pushed by Kuma right after the login [verify]
  try {
    await login(s, plan, false);
    await waitFor(() => pageList, deps.listMs == null ? 15000 : deps.listMs, "Kuma sent no status page list within 15 s of the login; nothing changed");
    const slug = plan.slug;
    const page = await emitAck(s, "getStatusPage", slug);
    if (!page || page.ok !== true || !page.config) throw fail("no status page " + slug + " in Kuma; run kuma_sync for it first (nothing changed)");
    const others = {};
    for (const p of (Array.isArray(pageList) ? pageList : Object.values(pageList || {}))) {
      if (!p || String(p.slug || "").toLowerCase() === slug) continue;
      for (const d of p.domainNameList || []) others[normHost(d)] = String(p.slug || p.id);
    }
    const existing = Array.isArray(page.config.domainNameList) ? page.config.domainNameList : [];
    const d = planDomains(existing, plan.add, plan.remove, others);
    const res = { ok: true, page: "/status/" + slug, domains: d.list.map(normHost), added: d.added, removed: d.removed, absent: d.absent,
      changed: d.added.length + d.removed.length > 0 };
    if (!res.changed) return res;
    const current = await publicGroups(deps, slug);
    if (current === null) throw fail("could not read the groups of status page " + slug + "; nothing saved (Kuma caches a missing page for 5 minutes: run it again later)");
    const { groups } = mergeGroups(current, "", []);
    const config = Object.assign({}, page.config, { domainNameList: d.list });
    const r = await emitAck(s, "saveStatusPage", slug, config, page.config.icon || "/icon.svg", groups);
    if (!r || r.ok !== true) throw fail("Kuma did not save the status page " + slug + ": " + kumaMsg(r));
    return res;
  } finally { s.close(); }
}

function run(plan, deps) {
  if (plan.action === "init") return init(plan, deps);
  return plan.action === "domain" ? domain(plan, deps) : sync(plan, deps);
}

// scrub(msg, password) -> msg without the password and control characters, short.
function scrub(msg, password) {
  let m = String(msg == null ? "" : msg);
  if (password) m = m.split(password).join("<password>");
  return m.replace(/[\u0000-\u001f\u007f]+/g, " ").slice(0, 500);
}

function loadIo() {
  let m;
  try { m = require("socket.io-client"); } catch (_) {
    try { m = require("/app/node_modules/socket.io-client"); } catch (e) {
      throw fail("socket.io-client is not in this container (is it the Kuma 2.x image?)");
    }
  }
  return m.io || m;
}

async function main() {
  // The budget counts from the start; arm() again once the monitors to add are known.
  const start = Date.now();
  let timer = null;
  const arm = (ms) => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      process.stdout.write(JSON.stringify({ ok: false, msg: "kuma.js gave up after " + Math.round(ms / 1000) + " s" }) + "\n");
      process.exit(1);
    }, Math.max(0, start + ms - Date.now()));
  };
  arm(hardTimeoutMs(0));
  let plan = null;
  try {
    const chunks = [];
    for await (const c of process.stdin) chunks.push(c);
    try { plan = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch (_) { throw fail("the plan on stdin is not JSON"); }
    validatePlan(plan);
    if (typeof fetch !== "function") throw fail("this Node has no fetch (Node 18 or newer needed)");
    const res = await run(plan, { io: loadIo(), fetch, onAdds: (n) => arm(hardTimeoutMs(n)) });
    process.stdout.write(JSON.stringify(res) + "\n");
    clearTimeout(timer);
    process.exit(0);
  } catch (e) {
    const pw = plan && typeof plan.password === "string" ? plan.password : "";
    process.stdout.write(JSON.stringify({ ok: false, msg: scrub((e && e.message) || e, pw) }) + "\n");
    clearTimeout(timer);
    process.exit(1);
  }
}

if (process.env.KUMA_JS_TEST === "1") {
  module.exports = { hardTimeoutMs, validatePlan, planMonitors, mergeGroups, pageConfig, planDomains, normHost, normUrl, scrub, run,
    MONITOR_DEFAULTS, HOST_RE };
} else {
  main();
}
