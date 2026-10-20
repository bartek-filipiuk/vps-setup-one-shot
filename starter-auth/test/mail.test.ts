// Configuration, the transport options and the sign-in mail. Mail goes only through
// nodemailer's JSON transport here (MAIL_LOG=1): nothing leaves the machine.
import test from "node:test";
import assert from "node:assert/strict";
import { describe, readConfig } from "../lib/config.ts";
import { sendMail, transportOptions } from "../lib/mail.ts";
import { escapeHtml, signInMail } from "../lib/mail-templates.ts";
import { logger } from "./fake-db.ts";

const base = { SITE_URL: "https://app.example.com/", MAIL_FROM: "App <no-reply@example.com>" };

test("readConfig: MAIL_LOG=1 needs no SMTP and wins over it", () => {
  const c = readConfig({ ...base, MAIL_LOG: "1", SMTP_URL: "smtps://u:p@smtp.example.com" });
  assert.deepEqual(c, { siteUrl: "https://app.example.com", appName: "app.example.com", mail: { mode: "log", from: "App <no-reply@example.com>" } });
  assert.deepEqual(transportOptions(c.mail), { jsonTransport: true });
  const lines = describe(c, { SMTP_URL: "x" });
  assert.match(lines[0], /^mail: MAIL_LOG=1, nothing is sent: sign-in links go to this log, and anyone who reads the log can sign in/);
  assert.equal(lines[1], "mail: SMTP_URL is set but ignored while MAIL_LOG=1");
  assert.equal(readConfig({ SITE_URL: "http://localhost:3000", MAIL_LOG: "1", APP_NAME: " Demo " }).mail.from, "Demo <no-reply@example.com>");
});

test("readConfig: smtps:// is TLS on 465, smtp:// requires STARTTLS on 587, the password decoded", () => {
  const s = readConfig({ ...base, SMTP_URL: "smtps://apikey:p%40ss%3Aw%2Fd@smtp.example.com" });
  assert.deepEqual(s.mail, { mode: "smtp", from: base.MAIL_FROM, host: "smtp.example.com", port: 465, secure: true, user: "apikey", pass: "p@ss:w/d" });
  assert.equal(transportOptions(s.mail).requireTLS, false);
  const p = readConfig({ ...base, SMTP_URL: "smtp://me%40x.io:pw@mail.example.com:2525", APP_NAME: "Demo" });
  assert.equal(p.appName, "Demo");
  assert.deepEqual(transportOptions(p.mail), {
    host: "mail.example.com", port: 2525, secure: false, requireTLS: true, auth: { user: "me@x.io", pass: "pw" },
    connectionTimeout: 10000, greetingTimeout: 10000, socketTimeout: 20000,
  });
  assert.deepEqual(transportOptions(readConfig({ ...base, SMTP_URL: "smtp://u:p@h.example.com" }).mail).port, 587);
});

test("describe: host and port only, never the password; http on production warns", () => {
  const c = readConfig({ ...base, SMTP_URL: "smtps://user:secretpw@smtp.example.com:465" });
  const lines = describe(c, { NODE_ENV: "production" });
  assert.deepEqual(lines, ["mail: smtp smtp.example.com:465 (TLS)"]);
  assert.ok(!lines.join(" ").includes("secretpw"));
  const h = readConfig({ SITE_URL: "http://app.example.com", MAIL_LOG: "1" });
  assert.match(describe(h, { NODE_ENV: "production" }).at(-1)!, /SITE_URL is http:\/\/, so the session cookie is not marked Secure/);
  assert.equal(describe(h, {}).length, 1);
});

test("readConfig: missing or wrong settings throw, and no message repeats the URL", () => {
  const cases: [Record<string, string>, RegExp][] = [
    [{}, /SITE_URL is not set/],
    [{ SITE_URL: "app.example.com" }, /SITE_URL is not set/],
    [{ SITE_URL: "ftp://app.example.com", MAIL_LOG: "1" }, /must start with https:\/\/ or http:\/\//],
    [{ ...base }, /SMTP_URL is not set \(or MAIL_LOG=1 for a log-only dev run\)/],
    [{ ...base, MAIL_LOG: "0" }, /SMTP_URL is not set/],
    [{ SITE_URL: base.SITE_URL, SMTP_URL: "smtps://u:p@h.example.com" }, /MAIL_FROM is not set/],
    [{ ...base, SMTP_URL: "not a url secretpw" }, /SMTP_URL is not a URL/],
    [{ ...base, SMTP_URL: "https://u:secretpw@h.example.com" }, /must start with smtps:\/\/ or smtp:\/\//],
    [{ ...base, SMTP_URL: "smtps://h.example.com" }, /no login or password/],
    [{ ...base, SMTP_URL: "smtps://u:%E0%A4%A@h.example.com" }, /broken %-escape/],
  ];
  for (const [env, re] of cases) {
    assert.throws(() => readConfig(env), (err: Error) => re.test(err.message) && !err.message.includes("secretpw"), JSON.stringify(env));
  }
});

test("signInMail: the app name in the subject, the link once in text, escaped in html", () => {
  const link = "https://app.example.com/auth/callback?token=abc_DEF-123";
  const m = signInMail({ appName: `A & B <"x">`, link, minutes: 15 });
  assert.equal(m.subject, `Sign in to A & B <"x">`);
  assert.equal(m.text.split(link).length - 1, 1);
  assert.match(m.text, /once, for 15 minutes/);
  assert.equal(m.html.split(`href="${link}"`).length - 1, 1);
  assert.ok(m.html.includes("A &amp; B &lt;&quot;x&quot;&gt;"));
  assert.ok(!m.html.includes(`<"x">`));
  assert.equal(escapeHtml(`<a href="x">'&</a>`), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&lt;/a&gt;");
});

test("sendMail with MAIL_LOG=1: one JSON line with to, subject and text; nothing sent", async () => {
  const c = readConfig({ SITE_URL: "http://127.0.0.1:3000", MAIL_LOG: "1" });
  const log = logger();
  await sendMail(c.mail, { to: "ci@example.com", subject: "Sign in", text: "link: http://x/auth/callback?token=t", html: "<p>x</p>" }, log);
  assert.equal(log.lines.length, 1);
  assert.match(log.lines[0], /^mail: \{/);
  assert.deepEqual(JSON.parse(log.lines[0].slice("mail: ".length)), { to: "ci@example.com", subject: "Sign in", text: "link: http://x/auth/callback?token=t" });
});
