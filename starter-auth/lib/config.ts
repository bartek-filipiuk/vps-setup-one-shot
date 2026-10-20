// The app's settings from the environment, checked once at start (instrumentation.ts exits on
// a missing one) and read again where they are used. No secret is ever part of a message here:
// SMTP_URL is described by its host and port only.
export type MailSettings =
  | { mode: "log"; from: string }
  | { mode: "smtp"; from: string; host: string; port: number; secure: boolean; user: string; pass: string };

export type Config = { siteUrl: string; appName: string; mail: MailSettings };

type Env = Record<string, string | undefined>;

export function readConfig(env: Env = process.env): Config {
  let site: URL;
  try {
    site = new URL(env.SITE_URL ?? "");
  } catch {
    throw new Error("SITE_URL is not set to the public address (like https://app.example.com)");
  }
  if (site.protocol !== "https:" && site.protocol !== "http:") throw new Error("SITE_URL must start with https:// or http://");
  const siteUrl = site.origin;
  const appName = (env.APP_NAME ?? "").trim() || site.hostname;
  const from = (env.MAIL_FROM ?? "").trim();

  if (env.MAIL_LOG === "1") return { siteUrl, appName, mail: { mode: "log", from: from || `${appName} <no-reply@example.com>` } };

  const raw = env.SMTP_URL ?? "";
  if (!raw) throw new Error("SMTP_URL is not set (or MAIL_LOG=1 for a log-only dev run)");
  if (!from) throw new Error('MAIL_FROM is not set (like "App <no-reply@example.com>", an address the provider verified)');
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    // Never echo the value: it holds the SMTP password.
    throw new Error("SMTP_URL is not a URL (smtps://LOGIN:PASSWORD@HOST:465 or smtp://LOGIN:PASSWORD@HOST:587; percent-encode @ : / % # in the password)");
  }
  if (u.protocol !== "smtp:" && u.protocol !== "smtps:") throw new Error("SMTP_URL must start with smtps:// or smtp://");
  if (!u.hostname) throw new Error("SMTP_URL has no host");
  if (!u.username || !u.password) throw new Error("SMTP_URL has no login or password");
  const secure = u.protocol === "smtps:";
  let user: string, pass: string;
  try {
    user = decodeURIComponent(u.username);
    pass = decodeURIComponent(u.password);
  } catch {
    throw new Error("SMTP_URL: the login or password has a broken %-escape");
  }
  return {
    siteUrl,
    appName,
    mail: { mode: "smtp", from, host: u.hostname, port: u.port ? Number(u.port) : secure ? 465 : 587, secure, user, pass },
  };
}

// describe -> the one startup line about mail and the warnings that go with it.
export function describe(c: Config, env: Env = process.env): string[] {
  const lines: string[] = [];
  if (c.mail.mode === "log") {
    lines.push("mail: MAIL_LOG=1, nothing is sent: sign-in links go to this log, and anyone who reads the log can sign in. Never on production.");
    if (env.SMTP_URL) lines.push("mail: SMTP_URL is set but ignored while MAIL_LOG=1");
  } else {
    lines.push(`mail: smtp ${c.mail.host}:${c.mail.port} (${c.mail.secure ? "TLS" : "STARTTLS required"})`);
  }
  if (env.NODE_ENV === "production" && c.siteUrl.startsWith("http:")) {
    lines.push("auth: SITE_URL is http://, so the session cookie is not marked Secure; use the https:// address on a server");
  }
  return lines;
}

// configOrExit: at start; a missing setting stops the container (the old version keeps running
// on Coolify, as with a failed migration) instead of failing on the first sign-in.
export function configOrExit(): void {
  try {
    const c = readConfig();
    for (const l of describe(c)) console.log(l);
  } catch (err) {
    console.error(`config: ${(err as Error).message}`);
    process.exit(1);
  }
}
