// The sign-in logic and the SQL it sends, against a fake database (no Postgres). The real
// database path is proven end to end by test/fixtures.sh starter-auth.
import test from "node:test";
import assert from "node:assert/strict";
import {
  clientIp, consumeLoginToken, cookieAttributes, createLoginToken, createSession, deleteSession, EMAIL_LIMIT,
  handleCallback, handleSignIn, handleSignOut, hashToken, IP_LIMIT, newToken, normalizeEmail, peekLoginToken,
  rateHit, readSession, sameOrigin, sessionCookie, upsertUser, validRawToken, type Mail,
} from "../lib/auth-core.ts";
import { fakeDb, logger, rows } from "./fake-db.ts";

const SITE = "https://app.example.com";
const site = { siteUrl: SITE, appName: "App" };
const render = (link: string) => ({ subject: "s", text: link, html: link });

test("normalizeEmail: trimmed, lowercased, a shape check and 254 characters at most", () => {
  assert.equal(normalizeEmail("  Ann@Example.COM "), "ann@example.com");
  assert.equal(normalizeEmail("a.b+c@sub.example.org"), "a.b+c@sub.example.org");
  for (const bad of ["", "ann", "ann@example", "ann @example.com", "@example.com", "ann@.", null, undefined, 42, `${"a".repeat(250)}@x.io`]) {
    assert.equal(normalizeEmail(bad), null, String(bad));
  }
});

test("newToken and hashToken: 43-character base64url, sha256 hex, never the same twice", () => {
  const a = newToken();
  const b = newToken();
  assert.match(a.raw, /^[A-Za-z0-9_-]{43}$/);
  assert.match(a.hash, /^[0-9a-f]{64}$/);
  assert.notEqual(a.raw, b.raw);
  assert.equal(hashToken(a.raw), a.hash);
  assert.notEqual(a.hash, a.raw);
  assert.equal(validRawToken(a.raw), true);
  for (const bad of ["", "x", a.raw + "x", a.raw.slice(1) + "=", undefined, 7]) assert.equal(validRawToken(bad), false, String(bad));
});

test("sameOrigin: Origin first, Referer as the fallback, SITE_URL decides", () => {
  assert.equal(sameOrigin(SITE, null, SITE), true);
  assert.equal(sameOrigin(SITE, null, `${SITE}/`), true);
  assert.equal(sameOrigin("https://evil.example", `${SITE}/`, SITE), false); // Origin wins over Referer
  assert.equal(sameOrigin(null, `${SITE}/auth/callback?token=x`, SITE), true);
  assert.equal(sameOrigin(null, "https://evil.example/", SITE), false);
  assert.equal(sameOrigin(null, null, SITE), false);
  assert.equal(sameOrigin("null", null, SITE), false);
  assert.equal(sameOrigin(null, "not a url", SITE), false);
  assert.equal(sameOrigin("http://app.example.com", null, SITE), false); // scheme counts
  assert.equal(sameOrigin("http://127.0.0.1:3000", null, "http://127.0.0.1:3000"), true);
  assert.equal(sameOrigin("http://127.0.0.1:3001", null, "http://127.0.0.1:3000"), false); // port counts
  assert.equal(sameOrigin(SITE, null, "not a url"), false);
});

test("clientIp: the last X-Forwarded-For entry, unknown without one", () => {
  assert.equal(clientIp("1.1.1.1, 10.0.0.2"), "10.0.0.2");
  assert.equal(clientIp(" 2001:db8::1 "), "2001:db8::1");
  assert.equal(clientIp(null), "unknown");
  assert.equal(clientIp(""), "unknown");
  assert.equal(clientIp("a, "), "unknown");
});

test("rateHit: one upsert per key and window, over the limit only after it", async () => {
  const db = fakeDb(rows({ hits: 5 }), rows({ hits: 6 }));
  assert.equal(await rateHit(db, "email:a@b.co", 5), false);
  assert.equal(await rateHit(db, "email:a@b.co", 5), true);
  const sql = db.calls[0].text;
  assert.match(sql, /^insert into auth_rate \(key, window_start\) values \(\$1, to_timestamp\(floor\(extract\(epoch from now\(\)\) \/ 900\) \* 900\)\)/);
  assert.match(sql, /on conflict \(key, window_start\) do update set hits = auth_rate\.hits \+ 1 returning hits$/);
  assert.deepEqual(db.calls[0].values, ["email:a@b.co"]);
});

test("login tokens: only the hash is stored, single use is in the SQL", async () => {
  const t = newToken();
  const db = fakeDb(rows(), rows({ email: "a@b.co" }), rows({ email: "a@b.co" }), rows());
  await createLoginToken(db, t.hash, "a@b.co", "10.0.0.2");
  assert.match(db.calls[0].text, /^insert into login_tokens \(token_hash, email, expires_at, request_ip\) values \(\$1, \$2, now\(\) \+ make_interval\(mins => \$3\), \$4\)$/);
  assert.deepEqual(db.calls[0].values, [t.hash, "a@b.co", 15, "10.0.0.2"]);
  assert.equal(await peekLoginToken(db, t.hash), "a@b.co");
  assert.match(db.calls[1].text, /^select email from login_tokens where token_hash = \$1 and used_at is null and expires_at > now\(\)$/);
  assert.equal(await consumeLoginToken(db, t.hash), "a@b.co");
  assert.equal(await consumeLoginToken(db, t.hash), null);
  assert.match(db.calls[2].text, /^update login_tokens set used_at = now\(\) where token_hash = \$1 and used_at is null and expires_at > now\(\) returning email$/);
  for (const c of db.calls) assert.ok(!c.values.includes(t.raw), "the raw token never reaches the database");
});

test("users and sessions: upsert at sign-in, sessions by hash, expiry in the join", async () => {
  const s = newToken();
  const db = fakeDb(rows({ id: "7" }), rows(), rows({ id: "7", email: "a@b.co" }), rows(), rows(), rows(), rows());
  assert.equal(await upsertUser(db, "a@b.co"), "7");
  assert.match(db.calls[0].text, /on conflict \(email\) do update set last_login_at = now\(\) returning id$/);
  await createSession(db, s.hash, "7");
  assert.deepEqual(db.calls[1].values, [s.hash, "7", 30]);
  assert.deepEqual(await readSession(db, s.raw), { id: "7", email: "a@b.co" });
  assert.match(db.calls[2].text, /join users u on u\.id = s\.user_id where s\.token_hash = \$1 and s\.expires_at > now\(\)$/);
  assert.deepEqual(db.calls[2].values, [s.hash]);
  assert.match(db.calls[3].text, /last_seen_at < now\(\) - interval '1 hour'$/);
  assert.equal(await readSession(db, s.raw), null);
  const before = db.calls.length;
  assert.equal(await readSession(db, "not-a-token"), null);
  assert.equal(await readSession(db, undefined), null);
  assert.equal(db.calls.length, before, "a malformed cookie sends no query");
  await deleteSession(db, s.raw);
  assert.deepEqual(db.calls.at(-1), { text: "delete from sessions where token_hash = $1", values: [s.hash] });
  await deleteSession(db, s.raw, true);
  assert.equal(db.calls.at(-1)!.text, "delete from sessions where user_id = (select user_id from sessions where token_hash = $1)");
});

test("cookie: HttpOnly, SameSite=Lax, Path=/, 30 days, Secure only on https", () => {
  assert.deepEqual(cookieAttributes(SITE), { httpOnly: true, sameSite: "lax", path: "/", maxAge: 2592000, secure: true });
  assert.equal(cookieAttributes("http://127.0.0.1:3000").secure, false);
  assert.equal(sessionCookie("abc", SITE), "session=abc; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax; Secure");
  assert.equal(sessionCookie("abc", "http://localhost:3000"), "session=abc; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax");
  assert.equal(sessionCookie("", SITE), "session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax; Secure");
});

function signIn(over: Partial<{ origin: string | null; referer: string | null; xff: string | null; email: unknown; company: unknown }> = {}) {
  return { origin: SITE, referer: null, xff: "10.0.0.2", email: "Ann@Example.com", company: null, ...over };
}
const cleanupAnswers = () => [rows(), rows(), rows()];

test("handleSignIn: one mail with a link to the confirm page, only the hash stored", async () => {
  const db = fakeDb(...cleanupAnswers(), rows({ hits: 1 }), rows({ hits: 1 }), rows());
  const sent: Mail[] = [];
  const log = logger();
  const a = await handleSignIn(db, signIn(), site, async (m) => { sent.push(m); }, render, log);
  assert.deepEqual(a, { status: 303, location: "/?sent=1" });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].to, "ann@example.com");
  const m = sent[0].text.match(/^https:\/\/app\.example\.com\/auth\/callback\?token=([A-Za-z0-9_-]{43})$/);
  assert.ok(m, sent[0].text);
  const insert = db.calls[5];
  assert.match(insert.text, /^insert into login_tokens/);
  assert.equal(insert.values[0], hashToken(m![1]));
  assert.deepEqual(db.calls[3].values, ["ip:10.0.0.2"]);
  assert.deepEqual(db.calls[4].values, ["email:ann@example.com"]);
  assert.match(db.calls[0].text, /^delete from login_tokens where expires_at < now\(\)/);
  assert.deepEqual(log.lines, ["auth: link requested"]);
  assert.ok(!log.lines.join("\n").includes(m![1]), "the token is never logged");
});

test("handleSignIn: another site, no origin, honeypot and a bad address send nothing", async () => {
  const none = async () => { throw new Error("must not send"); };
  for (const over of [{ origin: "https://evil.example" }, { origin: null }, { origin: null, referer: "https://evil.example/x" }]) {
    const db = fakeDb();
    assert.deepEqual(await handleSignIn(db, signIn(over), site, none, render, logger()), { status: 403 });
    assert.equal(db.calls.length, 0);
  }
  const hp = fakeDb();
  assert.deepEqual(await handleSignIn(hp, signIn({ company: "ACME" }), site, none, render, logger()), { status: 303, location: "/?sent=1" });
  assert.equal(hp.calls.length, 0);
  const bad = fakeDb();
  assert.deepEqual(await handleSignIn(bad, signIn({ email: "nope" }), site, none, render, logger()), { status: 303, location: "/?error=invalid" });
  assert.equal(bad.calls.length, 0);
});

test("handleSignIn: an IP over its limit is told busy; an address over its limit silently gets no mail", async () => {
  const none = async () => { throw new Error("must not send"); };
  const ip = fakeDb(...cleanupAnswers(), rows({ hits: IP_LIMIT + 1 }));
  assert.deepEqual(await handleSignIn(ip, signIn(), site, none, render, logger()), { status: 303, location: "/?error=busy" });
  assert.equal(ip.calls.length, 4);
  const log = logger();
  const em = fakeDb(...cleanupAnswers(), rows({ hits: 1 }), rows({ hits: EMAIL_LIMIT + 1 }));
  assert.deepEqual(await handleSignIn(em, signIn(), site, none, render, log), { status: 303, location: "/?sent=1" });
  assert.equal(em.calls.length, 5, "no token row");
  assert.deepEqual(log.lines, ["auth: link not sent, address over its limit"]);
});

test("handleSignIn: a failed mail removes the token row and says failed; a database error too", async () => {
  const db = fakeDb(...cleanupAnswers(), rows({ hits: 1 }), rows({ hits: 1 }), rows(), rows());
  const log = logger();
  const a = await handleSignIn(db, signIn(), site, async () => { throw new Error("EAUTH 535"); }, render, log);
  assert.deepEqual(a, { status: 303, location: "/?error=failed" });
  assert.equal(db.calls[6].text, "delete from login_tokens where token_hash = $1");
  assert.equal(db.calls[6].values[0], db.calls[5].values[0]);
  assert.deepEqual(log.lines, ["auth: sign-in request failed: EAUTH 535"]);
  const down = fakeDb(new Error("connection refused"));
  assert.deepEqual(await handleSignIn(down, signIn(), site, async () => {}, render, logger()), { status: 303, location: "/?error=failed" });
});

test("handleCallback: the token once, a user, a new session cookie, a fixed redirect", async () => {
  const t = newToken();
  const db = fakeDb(rows({ email: "a@b.co" }), rows({ id: "9" }), rows());
  const log = logger();
  const a = await handleCallback(db, { origin: SITE, referer: null, token: t.raw }, SITE, log);
  assert.equal(a.status, 303);
  assert.equal(a.location, "/account");
  const m = a.cookie!.match(/^session=([A-Za-z0-9_-]{43}); Path=\/; Max-Age=2592000; HttpOnly; SameSite=Lax; Secure$/);
  assert.ok(m, a.cookie);
  assert.deepEqual(db.calls[0].values, [t.hash]);
  assert.match(db.calls[0].text, /^update login_tokens set used_at = now\(\)/);
  assert.deepEqual(db.calls[2].values, [hashToken(m![1]), "9", 30]);
  assert.notEqual(m![1], t.raw, "the session is not the link token");
  assert.deepEqual(log.lines, ["auth: signed in user 9"]);
});

test("handleCallback: another site, a used or malformed token, a database error", async () => {
  const t = newToken();
  const evil = fakeDb();
  assert.deepEqual(await handleCallback(evil, { origin: "https://evil.example", referer: null, token: t.raw }, SITE, logger()), { status: 403 });
  assert.equal(evil.calls.length, 0);
  const used = fakeDb(rows());
  assert.deepEqual(await handleCallback(used, { origin: SITE, referer: null, token: t.raw }, SITE, logger()), { status: 303, location: "/?error=expired" });
  assert.equal(used.calls.length, 1, "no user, no session");
  const junk = fakeDb();
  assert.deepEqual(await handleCallback(junk, { origin: SITE, referer: null, token: "x' or 1=1" }, SITE, logger()), { status: 303, location: "/?error=expired" });
  assert.equal(junk.calls.length, 0);
  const down = fakeDb(new Error("boom"));
  assert.deepEqual(await handleCallback(down, { origin: SITE, referer: null, token: t.raw }, SITE, logger()), { status: 303, location: "/?error=failed" });
});

test("handleSignOut: same origin only, the row deleted, the cookie cleared", async () => {
  const s = newToken();
  const db = fakeDb(rows(), rows());
  const cleared = "session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax; Secure";
  assert.deepEqual(await handleSignOut(db, { origin: SITE, referer: null, session: s.raw, everywhere: false }, SITE, logger()), { status: 303, location: "/", cookie: cleared });
  assert.deepEqual(db.calls[0].values, [s.hash]);
  await handleSignOut(db, { origin: SITE, referer: null, session: s.raw, everywhere: true }, SITE, logger());
  assert.match(db.calls[1].text, /where user_id = \(select user_id from sessions where token_hash = \$1\)$/);
  const evil = fakeDb();
  assert.deepEqual(await handleSignOut(evil, { origin: "https://evil.example", referer: null, session: s.raw, everywhere: false }, SITE, logger()), { status: 403 });
  assert.equal(evil.calls.length, 0);
  const anon = fakeDb();
  assert.deepEqual(await handleSignOut(anon, { origin: SITE, referer: null, session: undefined, everywhere: false }, SITE, logger()), { status: 303, location: "/", cookie: cleared });
  assert.equal(anon.calls.length, 0);
  const down = fakeDb(new Error("boom"));
  assert.deepEqual(await handleSignOut(down, { origin: SITE, referer: null, session: s.raw, everywhere: false }, SITE, logger()), { status: 303, location: "/account?error=failed" });
});
