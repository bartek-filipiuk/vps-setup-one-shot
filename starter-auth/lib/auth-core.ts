// Email-link sign-in without a library and without a signing secret: random tokens whose
// sha256 lives in Postgres (a dump or a read-only leak gives no live link or session). Pure
// logic with the database passed in, so test/auth-core.test.ts runs it against a fake one;
// lib/auth.ts and the route handlers are the Next.js glue.
import { createHash, randomBytes } from "node:crypto";

export type Db = {
  query(text: string, values?: unknown[]): Promise<{ rows: any[]; rowCount: number | null }>;
};
export type Log = { log(msg: string): void; error(msg: string): void };
export type User = { id: string; email: string };

export const LINK_MINUTES = 15;
export const SESSION_DAYS = 30;
export const IP_LIMIT = 20; // sign-in requests per IP per 15 minutes
export const EMAIL_LIMIT = 5; // sign-in mails per address per 15 minutes
export const COOKIE = "session";

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const RAW_TOKEN = /^[A-Za-z0-9_-]{43}$/; // 32 random bytes in base64url

// normalizeEmail -> the address trimmed and lowercased, or null when it is not one.
export function normalizeEmail(v: unknown): string | null {
  const e = String(v ?? "").trim().toLowerCase();
  return e.length <= 254 && EMAIL.test(e) ? e : null;
}

export function hashToken(raw: string): string {
  return createHash("sha256").update(raw).digest("hex");
}

// newToken -> raw goes to the user (link or cookie) only; hash goes to the database.
export function newToken(): { raw: string; hash: string } {
  const raw = randomBytes(32).toString("base64url");
  return { raw, hash: hashToken(raw) };
}

export function validRawToken(v: unknown): v is string {
  return typeof v === "string" && RAW_TOKEN.test(v);
}

// sameOrigin: the request's Origin (or, without one, the origin of its Referer) must be
// SITE_URL's origin. SITE_URL is configuration, not the Host header a proxy could pass on.
export function sameOrigin(origin: string | null, referer: string | null, siteUrl: string): boolean {
  let want: string;
  try {
    want = new URL(siteUrl).origin;
  } catch {
    return false;
  }
  if (origin) return origin === want;
  if (!referer) return false;
  try {
    return new URL(referer).origin === want;
  } catch {
    return false;
  }
}

// clientIp: the last X-Forwarded-For entry is the one Traefik (Coolify's proxy) appended;
// earlier entries come from the client and are not trusted.
export function clientIp(xff: string | null): string {
  return xff?.split(",").at(-1)?.trim().slice(0, 64) || "unknown";
}

// rateHit -> true when KEY went over LIMIT in the current 15-minute window (one statement, so
// two containers during a deploy count together).
export async function rateHit(db: Db, key: string, limit: number): Promise<boolean> {
  const { rows } = await db.query(
    `insert into auth_rate (key, window_start) values ($1, to_timestamp(floor(extract(epoch from now()) / 900) * 900))
     on conflict (key, window_start) do update set hits = auth_rate.hits + 1 returning hits`,
    [key.slice(0, 300)],
  );
  return Number(rows[0]?.hits ?? 0) > limit;
}

// cleanup: expired rows, cheap enough to run on every sign-in request (no worker needed).
export async function cleanup(db: Db): Promise<void> {
  await db.query("delete from login_tokens where expires_at < now() - interval '1 day'");
  await db.query("delete from sessions where expires_at < now()");
  await db.query("delete from auth_rate where window_start < now() - interval '1 day'");
}

export async function createLoginToken(db: Db, hash: string, email: string, ip: string): Promise<void> {
  await db.query(
    `insert into login_tokens (token_hash, email, expires_at, request_ip) values ($1, $2, now() + make_interval(mins => $3), $4)`,
    [hash, email, LINK_MINUTES, ip],
  );
}

// peekLoginToken -> the address of a valid, unused link, without using it (the confirm page).
export async function peekLoginToken(db: Db, hash: string): Promise<string | null> {
  const { rows } = await db.query(
    "select email from login_tokens where token_hash = $1 and used_at is null and expires_at > now()",
    [hash],
  );
  return rows[0]?.email ?? null;
}

// consumeLoginToken -> the address, once: the update is atomic, a second use gets no row.
export async function consumeLoginToken(db: Db, hash: string): Promise<string | null> {
  const { rows } = await db.query(
    "update login_tokens set used_at = now() where token_hash = $1 and used_at is null and expires_at > now() returning email",
    [hash],
  );
  return rows[0]?.email ?? null;
}

// upsertUser -> the user's id; users are created here, at the first sign-in, never at request
// time, so asking for a link behaves the same for known and unknown addresses.
export async function upsertUser(db: Db, email: string): Promise<string> {
  const { rows } = await db.query(
    `insert into users (email, last_login_at) values ($1, now())
     on conflict (email) do update set last_login_at = now() returning id`,
    [email],
  );
  return String(rows[0].id);
}

export async function createSession(db: Db, hash: string, userId: string): Promise<void> {
  await db.query(
    "insert into sessions (token_hash, user_id, expires_at) values ($1, $2, now() + make_interval(days => $3))",
    [hash, userId, SESSION_DAYS],
  );
}

// readSession -> the signed-in user for the raw cookie value, or null.
export async function readSession(db: Db, raw: string | undefined): Promise<User | null> {
  if (!validRawToken(raw)) return null;
  const hash = hashToken(raw);
  const { rows } = await db.query(
    `select u.id, u.email from sessions s join users u on u.id = s.user_id
     where s.token_hash = $1 and s.expires_at > now()`,
    [hash],
  );
  if (!rows[0]) return null;
  // At most one write an hour per session.
  await db.query("update sessions set last_seen_at = now() where token_hash = $1 and last_seen_at < now() - interval '1 hour'", [hash]);
  return { id: String(rows[0].id), email: rows[0].email };
}

export async function deleteSession(db: Db, raw: string, everywhere = false): Promise<void> {
  const hash = hashToken(raw);
  if (everywhere) {
    await db.query("delete from sessions where user_id = (select user_id from sessions where token_hash = $1)", [hash]);
  } else {
    await db.query("delete from sessions where token_hash = $1", [hash]);
  }
}

// cookieAttributes: Secure whenever the site is https (production behind Coolify always is);
// http only for a local run and the fixture.
export function cookieAttributes(siteUrl: string) {
  return {
    httpOnly: true,
    sameSite: "lax" as const,
    path: "/",
    maxAge: SESSION_DAYS * 24 * 60 * 60,
    secure: new URL(siteUrl).protocol === "https:",
  };
}

// sessionCookie -> the Set-Cookie header value; an empty value with Max-Age=0 clears it.
export function sessionCookie(raw: string, siteUrl: string): string {
  const a = cookieAttributes(siteUrl);
  const maxAge = raw ? a.maxAge : 0;
  return `${COOKIE}=${raw}; Path=${a.path}; Max-Age=${maxAge}; HttpOnly; SameSite=Lax${a.secure ? "; Secure" : ""}`;
}

export type Mail = { to: string; subject: string; text: string; html: string };
export type Answer = { status: number; location?: string; cookie?: string };

const see = (location: string, cookie?: string): Answer => ({ status: 303, location, ...(cookie ? { cookie } : {}) });
const SENT = "/?sent=1";

export type SignInRequest = { origin: string | null; referer: string | null; xff: string | null; email: unknown; company: unknown };

// handleSignIn: POST /api/auth/sign-in. The answer never depends on whether the address has an
// account (none exist before the first sign-in), and an address over its limit gets the same
// "sent" answer without a mail, so nobody can flood an inbox or probe for accounts.
export async function handleSignIn(
  db: Db,
  req: SignInRequest,
  site: { siteUrl: string; appName: string },
  send: (mail: Mail) => Promise<void>,
  render: (link: string) => Omit<Mail, "to">,
  log: Log = console,
): Promise<Answer> {
  if (!sameOrigin(req.origin, req.referer, site.siteUrl)) return { status: 403 };
  if (req.company) return see(SENT); // honeypot: real people never see this field
  const email = normalizeEmail(req.email);
  if (!email) return see("/?error=invalid");
  try {
    await cleanup(db);
    if (await rateHit(db, `ip:${clientIp(req.xff)}`, IP_LIMIT)) return see("/?error=busy");
    if (await rateHit(db, `email:${email}`, EMAIL_LIMIT)) {
      log.log("auth: link not sent, address over its limit");
      return see(SENT);
    }
    const token = newToken();
    await createLoginToken(db, token.hash, email, clientIp(req.xff));
    const link = new URL(`/auth/callback?token=${token.raw}`, site.siteUrl).href;
    try {
      await send({ to: email, ...render(link) });
    } catch (err) {
      await db.query("delete from login_tokens where token_hash = $1", [token.hash]);
      throw err;
    }
    log.log("auth: link requested");
    return see(SENT);
  } catch (err) {
    log.error(`auth: sign-in request failed: ${(err as Error).message}`);
    return see("/?error=failed");
  }
}

// handleCallback: POST /api/auth/callback (the confirm page's button). A link opened by a mail
// scanner (GET) uses nothing; a POST from another site is refused, so nobody can sign a browser
// into their own account (login CSRF).
export async function handleCallback(
  db: Db,
  req: { origin: string | null; referer: string | null; token: unknown },
  siteUrl: string,
  log: Log = console,
): Promise<Answer> {
  if (!sameOrigin(req.origin, req.referer, siteUrl)) return { status: 403 };
  if (!validRawToken(req.token)) return see("/?error=expired");
  try {
    const email = await consumeLoginToken(db, hashToken(req.token));
    if (!email) return see("/?error=expired");
    const id = await upsertUser(db, email);
    const session = newToken();
    await createSession(db, session.hash, id);
    log.log(`auth: signed in user ${id}`);
    return see("/account", sessionCookie(session.raw, siteUrl));
  } catch (err) {
    log.error(`auth: callback failed: ${(err as Error).message}`);
    return see("/?error=failed");
  }
}

// handleSignOut: POST /api/auth/sign-out; everywhere=1 ends every session of the user.
export async function handleSignOut(
  db: Db,
  req: { origin: string | null; referer: string | null; session: string | undefined; everywhere: boolean },
  siteUrl: string,
  log: Log = console,
): Promise<Answer> {
  if (!sameOrigin(req.origin, req.referer, siteUrl)) return { status: 403 };
  if (validRawToken(req.session)) {
    try {
      await deleteSession(db, req.session, req.everywhere);
    } catch (err) {
      log.error(`auth: sign-out failed: ${(err as Error).message}`);
      return see("/account?error=failed");
    }
  }
  return see("/", sessionCookie("", siteUrl));
}
