// kuma.js: drives Uptime Kuma 2.x from inside its own container (UPTIME.md; lib.sh kuma_run).
// Kuma 2.x has no REST API for writes: the web UI talks socket.io, and so does this script,
// through the socket.io-client that ships in the Kuma image (/app/node_modules) [verify].
// It talks to http://127.0.0.1:3001, so it works before DNS and HTTPS do.
//
// Input: one JSON plan on stdin (it carries the admin password, so it never goes on a command line):
//   {"action":"init","user":"admin","password":"..."}
//   {"action":"sync","user":"admin","password":"...","monitors":[{"name":"shop","url":"https://shop.example.com"}],
//    "page":{"slug":"acme","title":"Acme","description":"Status of Acme"},"group":"Acme"}
// Output: one JSON line, {"ok":true,...} with exit 0 or {"ok":false,"msg":"..."} with exit 1. The
// password is never printed. Gives up after 90 seconds.
//
// Never destructive: it never deletes a monitor, a status page or a group. A monitor is matched by
// its URL (case and a trailing slash ignored), so a renamed one is kept, and a status page keeps
// every group and monitor added by hand; ours are added to the group named in the plan.
"use strict";

const BASE = "http://127.0.0.1:3001";
const HARD_TIMEOUT_MS = 90000;
const SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

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

// validatePlan(plan) -> the plan, or throws with what is wrong (never echoing the password).
function validatePlan(p) {
  if (!p || typeof p !== "object" || Array.isArray(p)) throw fail("the plan is not a JSON object");
  if (p.action !== "init" && p.action !== "sync") throw fail("unknown action: " + JSON.stringify(p.action));
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
  return p;
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

// sync: one monitor per wanted URL, the status page, our monitors on it. Idempotent.
async function sync(plan, deps) {
  const s = await connect(deps, 20000);
  let monitorList = null;
  s.on("monitorList", (l) => { monitorList = l; });   // pushed by Kuma right after the login
  try {
    await login(s, plan, false);
    const listEnd = Date.now() + (deps.listMs == null ? 15000 : deps.listMs);
    while (monitorList === null) {
      if (Date.now() >= listEnd) throw fail("Kuma sent no monitor list within 15 s of the login");
      await sleep(50);
    }
    const { add, kept } = planMonitors(monitorList, plan.monitors);
    const ids = kept.map((k) => k.id), added = [];
    for (const m of add) {
      const r = await emitAck(s, "add", Object.assign({}, MONITOR_DEFAULTS, { name: m.name, url: m.url }));
      if (!r || r.ok !== true) throw fail("Kuma refused the monitor " + m.name + ": " + kumaMsg(r) + (added.length ? " (added before it: " + added.join(", ") + ")" : ""));
      ids.push(r.monitorID); added.push(m.name);
    }
    const slug = plan.page.slug;
    let page = await emitAck(s, "getStatusPage", slug);
    if (!page || page.ok !== true) {
      const r = await emitAck(s, "addStatusPage", plan.page.title, slug);
      if (!r || r.ok !== true) throw fail("Kuma refused the status page " + slug + ": " + kumaMsg(r));
      page = await emitAck(s, "getStatusPage", slug);
      if (!page || page.ok !== true) throw fail("the new status page " + slug + " cannot be read: " + kumaMsg(page));
    }
    // The groups as they are now (public JSON); without them a save would delete groups, so stop.
    const pub = await http(deps, "GET", "/api/status-page/" + slug).catch(() => ({ json: null }));
    if (!pub.json || !Array.isArray(pub.json.publicGroupList)) {
      throw fail("could not read the groups of status page " + slug + "; the page was not saved" + (added.length ? " (monitors added: " + added.join(", ") + ")" : ""));
    }
    const { groups } = mergeGroups(pub.json.publicGroupList, plan.group, ids);
    const config = pageConfig(page.config, plan.page);
    const r = await emitAck(s, "saveStatusPage", slug, config, (page.config && page.config.icon) || "/icon.svg", groups);
    if (!r || r.ok !== true) throw fail("Kuma did not save the status page " + slug + ": " + kumaMsg(r));
    return { ok: true, added, kept: kept.map((k) => k.name), page: "/status/" + slug, groups: groups.length };
  } finally { s.close(); }
}

function run(plan, deps) { return plan.action === "init" ? init(plan, deps) : sync(plan, deps); }

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
  const timer = setTimeout(() => {
    process.stdout.write(JSON.stringify({ ok: false, msg: "kuma.js gave up after 90 s" }) + "\n");
    process.exit(1);
  }, HARD_TIMEOUT_MS);
  let plan = null;
  try {
    const chunks = [];
    for await (const c of process.stdin) chunks.push(c);
    try { plan = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch (_) { throw fail("the plan on stdin is not JSON"); }
    validatePlan(plan);
    if (typeof fetch !== "function") throw fail("this Node has no fetch (Node 18 or newer needed)");
    const res = await run(plan, { io: loadIo(), fetch });
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
  module.exports = { validatePlan, planMonitors, mergeGroups, pageConfig, normUrl, scrub, run, MONITOR_DEFAULTS };
} else {
  main();
}
