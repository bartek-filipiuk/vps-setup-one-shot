// Self-check for kuma.js against a fake Uptime Kuma (a fake socket.io client and a fake fetch).
// No container, no network. Run from the repo root: node test/kuma.test.js (prints ALL PASSED).
"use strict";
process.env.KUMA_JS_TEST = "1";
const path = require("path");
const fs = require("fs");
const { spawnSync } = require("child_process");
const assert = require("assert");
const K = require(path.join(__dirname, "..", "kuma.js"));

let fails = 0;
const pending = [];
function ok(name, fn) {
  pending.push(async () => {
    try { await fn(); console.log("ok   " + name); } catch (e) { fails++; console.log("FAIL " + name + ": " + (e && e.stack || e)); }
  });
}

// A fake Kuma 2.x: the database page, the admin, monitors, status pages and their groups.
function fakeKuma(opts = {}) {
  const st = Object.assign({
    dbNeedSetup: false, users: {}, monitors: {}, pages: {}, nextId: 1, events: [], connectFails: 0,
    tokenRequired: false, publicDown: false, sendMonitorList: true,
  }, opts);
  function handle(sock, ev, args) {
    st.events.push(ev);
    const cb = args.pop();
    const reply = (v) => setImmediate(() => cb(v));
    switch (ev) {
      case "needSetup": return reply(Object.keys(st.users).length === 0);
      case "setup": {
        const [u, p] = args;
        if (Object.keys(st.users).length) return reply({ ok: false, msg: "Uptime Kuma has been initialized. If you want to run setup again, please delete the database." });
        st.users[u] = p; return reply({ ok: true, msg: "successAdded" });
      }
      case "login": {
        const [d] = args;
        if (st.users[d.username] !== d.password) return reply({ ok: false, msg: "authIncorrectCreds" });
        if (st.tokenRequired) return reply({ tokenRequired: true });
        sock.loggedIn = true;
        reply({ ok: true, token: "jwt" });
        if (st.sendMonitorList) setImmediate(() => sock.push("monitorList", Object.assign({}, st.monitors)));
        return;
      }
      default:
        if (!sock.loggedIn) return reply({ ok: false, msg: "You are not logged in." });
    }
    switch (ev) {
      case "add": {
        const m = args[0]; const id = st.nextId++;
        st.monitors[id] = Object.assign({ id }, m); st.lastAdded = m;
        return reply({ ok: true, msg: "successAdded", monitorID: id });
      }
      case "getStatusPage": {
        const p = st.pages[args[0]];
        return reply(p ? { ok: true, config: p.config } : { ok: false, msg: "No slug?" });
      }
      case "addStatusPage": {
        const [title, slug] = args;
        st.pages[slug] = { config: { slug, title, description: null, icon: "/icon.svg", domainNameList: [], customCSS: "" }, groups: [] };
        return reply({ ok: true, msg: "successAdded" });
      }
      case "saveStatusPage": {
        const [slug, config, img, groups] = args;
        st.saved = { slug, config, img, groups };
        let gid = 100;
        st.pages[slug] = { config, groups: groups.map((g) => Object.assign({ id: g.id != null ? g.id : gid++ }, g)) };
        return reply({ ok: true, publicGroupList: st.pages[slug].groups });
      }
      default: return reply({ ok: false, msg: "unknown event " + ev });
    }
  }
  const io = () => {
    const h = {};
    const sock = {
      loggedIn: false,
      on(ev, fn) { (h[ev] = h[ev] || []).push(fn); },
      once(ev, fn) { (h[ev] = h[ev] || []).push(fn); },
      push(ev, ...a) { for (const fn of h[ev] || []) fn(...a); },
      emit(ev, ...args) { handle(sock, ev, args); },
      close() { st.closed = (st.closed || 0) + 1; },
    };
    setImmediate(() => {
      if (st.connectFails > 0) { st.connectFails--; sock.push("connect_error", new Error("xhr poll error")); }
      else sock.push("connect");
    });
    return sock;
  };
  const fetch = async (url, o = {}) => {
    const p = url.replace("http://127.0.0.1:3001", "");
    st.events.push("http " + (o.method || "GET") + " " + p);
    const res = (status, body) => ({ status, text: async () => (typeof body === "string" ? body : JSON.stringify(body)) });
    if (p === "/setup-database-info") {
      return st.dbNeedSetup ? res(200, { runningSetup: false, needSetup: true, isEnabledEmbeddedMariaDB: true }) : res(200, "<!DOCTYPE html><html></html>");
    }
    if (p === "/setup-database" && o.method === "POST") {
      st.dbBody = JSON.parse(o.body); st.dbNeedSetup = false; return res(200, { ok: true });
    }
    const m = p.match(/^\/api\/status-page\/([a-z0-9-]+)$/);
    if (m) {
      if (st.publicDown || !st.pages[m[1]]) return res(404, { msg: "Not Found" });
      const pg = st.pages[m[1]];
      return res(200, { config: pg.config, incident: null, maintenanceList: [],
        publicGroupList: pg.groups.map((g) => ({ id: g.id, name: g.name, weight: g.weight,
          monitorList: g.monitorList.map((x) => Object.assign({ id: x.id, name: (st.monitors[x.id] || {}).name, type: "http" },
            x.sendUrl !== undefined ? { sendUrl: x.sendUrl } : {})) })) });
    }
    return res(404, "Not Found");
  };
  return { st, deps: { io, fetch, retryMs: 0 } };
}

const PW = "pw+SECRET/abc=123xyz";
const syncPlan = (over = {}) => Object.assign({
  action: "sync", user: "admin", password: PW, group: "Acme",
  monitors: [{ name: "shop", url: "https://shop.example.com" }, { name: "starter", url: "https://starter.example.com" }],
  page: { slug: "acme", title: "Acme", description: "Status of Acme" },
}, over);

ok("validatePlan accepts init and sync", () => {
  K.validatePlan({ action: "init", user: "admin", password: PW });
  K.validatePlan(syncPlan());
});
ok("validatePlan refuses bad plans without echoing the password", () => {
  const bad = [
    [null, /not a JSON object/], [[], /not a JSON object/], [{ action: "delete", user: "a", password: PW }, /unknown action/],
    [{ action: "init", password: PW }, /no user/], [{ action: "init", user: "a" }, /no password/],
    [syncPlan({ page: { slug: "Acme Corp", title: "x" } }), /not a status page slug/],
    [syncPlan({ page: { slug: "-acme", title: "x" } }), /not a status page slug/],
    [syncPlan({ page: { slug: "acme", title: "" } }), /no title/],
    [syncPlan({ group: "" }), /no group/], [syncPlan({ monitors: "x" }), /no monitor list/],
    [syncPlan({ monitors: [{ name: "x", url: "ftp://x" }] }), /not a monitor/],
    [syncPlan({ monitors: [{ name: "", url: "https://x.example.com" }] }), /not a monitor/],
  ];
  for (const [p, re] of bad) {
    assert.throws(() => K.validatePlan(p), (e) => re.test(e.message) && !e.message.includes(PW), JSON.stringify(p && p.action));
  }
});
ok("planMonitors matches by URL, case and trailing slash ignored, whatever the name", () => {
  const list = { 4: { id: 4, name: "renamed by hand", url: "HTTPS://Shop.Example.com/" }, 7: { id: 7, name: "push", type: "push", url: null } };
  const r = K.planMonitors(list, [{ name: "shop", url: "https://shop.example.com" }, { name: "starter", url: "https://starter.example.com" },
    { name: "starter again", url: "https://starter.example.com/" }]);
  assert.deepStrictEqual(r, { add: [{ name: "starter", url: "https://starter.example.com" }], kept: [{ name: "shop", url: "https://shop.example.com", id: 4 }] });
  assert.deepStrictEqual(K.planMonitors([], []), { add: [], kept: [] });
});
ok("mergeGroups keeps every group and hand-added monitor, appends ours once", () => {
  const pub = [{ id: 1, name: "Infra", weight: 1, monitorList: [{ id: 9, name: "db", sendUrl: 0 }, { id: 4, name: "shop" }] },
    { id: 2, name: "Acme", weight: 2, monitorList: [{ id: 5, name: "hand" }] }];
  const r = K.mergeGroups(pub, "Acme", [4, 6, 6]);
  assert.deepStrictEqual(r.groups, [{ id: 1, name: "Infra", weight: 1, monitorList: [{ id: 9, sendUrl: 0 }, { id: 4 }] },
    { id: 2, name: "Acme", weight: 2, monitorList: [{ id: 5 }, { id: 6 }] }]);
  assert.strictEqual(r.placed, 1);
  const n = K.mergeGroups(pub, "New", [6]);
  assert.deepStrictEqual(n.groups[2], { name: "New", weight: 3, monitorList: [{ id: 6 }] });
  assert.strictEqual(n.groups.length, 3);
  const same = K.mergeGroups(pub, "Acme", [9, 5]);
  assert.strictEqual(same.placed, 0);
  assert.deepStrictEqual(same.groups.map((g) => g.monitorList.length), [2, 1]);
  assert.deepStrictEqual(K.mergeGroups([], "Apps", []).groups, []);
});
ok("pageConfig keeps the page's own domains and fields, sets ours", () => {
  const c = K.pageConfig({ slug: "acme", title: "Old", icon: "/upload/x.png", domainNameList: ["status.acme.com"], customCSS: "body{}", analyticsId: "a1" },
    { slug: "acme", title: "Acme", description: "Status of Acme" });
  assert.deepStrictEqual(c.domainNameList, ["status.acme.com"]);
  assert.strictEqual(c.customCSS, "body{}"); assert.strictEqual(c.analyticsId, "a1"); assert.strictEqual(c.icon, "/upload/x.png");
  assert.strictEqual(c.title, "Acme"); assert.strictEqual(c.showPoweredBy, false); assert.strictEqual(c.autoRefreshInterval, 300);
  assert.deepStrictEqual(K.pageConfig(null, { slug: "a", title: "A" }).domainNameList, []);
});
ok("scrub removes the password and control characters", () => {
  assert.strictEqual(K.scrub("bad " + PW + "\nnext", PW), "bad <password> next");
});

ok("init on a fresh volume: SQLite, then the admin, then a login", async () => {
  const { st, deps } = fakeKuma({ dbNeedSetup: true, connectFails: 2 });
  const r = await K.run({ action: "init", user: "admin", password: PW }, deps);
  assert.deepStrictEqual(r, { ok: true, db_setup: true, admin_created: true });
  assert.deepStrictEqual(st.dbBody, { dbConfig: { type: "sqlite" } });
  assert.strictEqual(st.users.admin, PW);
  assert.deepStrictEqual(st.events.filter((e) => !e.startsWith("http")), ["needSetup", "setup", "login"]);
});
ok("init a second time: nothing created", async () => {
  const { st, deps } = fakeKuma({ users: { admin: PW } });
  const r = await K.run({ action: "init", user: "admin", password: PW }, deps);
  assert.deepStrictEqual(r, { ok: true, db_setup: false, admin_created: false });
  assert.ok(!st.events.includes("setup")); assert.ok(!st.events.includes("http POST /setup-database"));
});
ok("init when someone else created the admin", async () => {
  const { deps } = fakeKuma({ users: { someone: "x" } });
  await assert.rejects(K.run({ action: "init", user: "admin", password: PW }, deps), /admin exists and kuma\.env does not open it \(authIncorrectCreds\)/);
});

ok("sync: existing monitor kept, new one added with our defaults, page created, groups merged", async () => {
  const { st, deps } = fakeKuma({ users: { admin: PW }, nextId: 10,
    monitors: { 4: { id: 4, name: "Shop by hand", url: "https://shop.example.com/" }, 9: { id: 9, name: "db", url: "https://db.example.com" } } });
  const r = await K.run(syncPlan(), deps);
  assert.deepStrictEqual(r, { ok: true, added: ["starter"], kept: ["shop"], page: "/status/acme", groups: 1 });
  const a = st.lastAdded;
  assert.strictEqual(a.url, "https://starter.example.com"); assert.strictEqual(a.name, "starter");
  assert.strictEqual(a.type, "http"); assert.strictEqual(a.interval, 60); assert.strictEqual(a.maxretries, 1);
  assert.strictEqual(a.retryInterval, 30); assert.strictEqual(a.timeout, 30); assert.deepStrictEqual(a.accepted_statuscodes, ["200-299"]);
  assert.deepStrictEqual(st.saved.groups, [{ name: "Acme", weight: 1, monitorList: [{ id: 4 }, { id: 10 }] }]);
  assert.strictEqual(st.saved.config.title, "Acme"); assert.strictEqual(st.saved.config.description, "Status of Acme");
  assert.strictEqual(st.saved.img, "/icon.svg");
});
ok("sync again with a hand-made group: nothing added, nothing removed, never a delete", async () => {
  const { st, deps } = fakeKuma({ users: { admin: PW }, nextId: 10,
    monitors: { 4: { id: 4, name: "shop", url: "https://shop.example.com" }, 10: { id: 10, name: "starter", url: "https://starter.example.com" },
                9: { id: 9, name: "db", url: "https://db.example.com" } },
    pages: { acme: { config: { slug: "acme", title: "Acme", icon: "/upload/logo.png", domainNameList: ["status.acme.com"] },
      groups: [{ id: 1, name: "Infra", weight: 1, monitorList: [{ id: 9, sendUrl: 1 }] }, { id: 2, name: "Acme", weight: 2, monitorList: [{ id: 4 }] }] } } });
  const r = await K.run(syncPlan(), deps);
  assert.deepStrictEqual(r, { ok: true, added: [], kept: ["shop", "starter"], page: "/status/acme", groups: 2 });
  assert.deepStrictEqual(st.saved.groups, [{ id: 1, name: "Infra", weight: 1, monitorList: [{ id: 9, sendUrl: 1 }] },
    { id: 2, name: "Acme", weight: 2, monitorList: [{ id: 4 }, { id: 10 }] }]);
  assert.deepStrictEqual(st.saved.config.domainNameList, ["status.acme.com"]);
  assert.strictEqual(st.saved.img, "/upload/logo.png");
  assert.ok(!st.events.includes("addStatusPage") && !st.events.includes("add"));
  assert.ok(!st.events.some((e) => /delete/i.test(e)), st.events.join(","));
});
ok("sync with 2FA on: a clear error", async () => {
  const { deps } = fakeKuma({ users: { admin: PW }, tokenRequired: true });
  await assert.rejects(K.run(syncPlan(), deps), /2FA is on/);
});
ok("sync with a wrong password", async () => {
  const { deps } = fakeKuma({ users: { admin: "other" } });
  await assert.rejects(K.run(syncPlan(), deps), /admin exists and kuma\.env does not open it/);
});
ok("sync: the groups cannot be read -> the page is not saved", async () => {
  const { st, deps } = fakeKuma({ users: { admin: PW }, publicDown: true });
  await assert.rejects(K.run(syncPlan(), deps), /could not read the groups of status page acme; the page was not saved \(monitors added: shop, starter\)/);
  assert.ok(!st.events.includes("saveStatusPage"));
});
ok("sync: no monitor list after the login -> error", async () => {
  const { deps } = fakeKuma({ users: { admin: PW }, sendMonitorList: false }); deps.listMs = 200;
  await assert.rejects(K.run(syncPlan(), deps), /no monitor list within 15 s/);
});
ok("kuma.js under node -e: a bad plan on stdin is one JSON line and exit 1", () => {
  const src = fs.readFileSync(path.join(__dirname, "..", "kuma.js"), "utf8");
  const env = Object.assign({}, process.env); delete env.KUMA_JS_TEST;
  for (const [input, re] of [["not json", /the plan on stdin is not JSON/], [JSON.stringify({ action: "init", user: "admin" }), /no password/],
    [JSON.stringify({ action: "nope", user: "admin", password: PW }), /unknown action/]]) {
    const r = spawnSync(process.execPath, ["-e", src], { input, env, encoding: "utf8", timeout: 20000 });
    assert.strictEqual(r.status, 1, r.stderr);
    const lines = r.stdout.trim().split("\n");
    assert.strictEqual(lines.length, 1, r.stdout);
    const j = JSON.parse(lines[0]);
    assert.strictEqual(j.ok, false); assert.ok(re.test(j.msg), j.msg); assert.ok(!r.stdout.includes(PW));
  }
});

(async () => {
  for (const t of pending) await t();
  console.log();
  if (fails === 0) console.log("ALL PASSED"); else { console.log(fails + " FAILED"); process.exit(1); }
})();
