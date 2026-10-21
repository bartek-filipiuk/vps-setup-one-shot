// The Next.js side of sign-in: the session cookie, the signed-in user for a page, and an
// answer of lib/auth-core.ts as a Response. Server only.
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { pool } from "./db.ts";
import { cookieAttributes, cookieName, readSession, type Answer, type User } from "./auth-core.ts";
import { readConfig } from "./config.ts";

// sessionCookieValue -> the raw session cookie of this request, under the name SITE_URL gives
// (lib/auth-core.ts cookieName: __Host-session on https, session on http).
export async function sessionCookieValue(): Promise<string | undefined> {
  return (await cookies()).get(cookieName(cookieAttributes(readConfig().siteUrl).secure))?.value;
}

// currentUser -> the signed-in user, or null (also when the database does not answer: the page
// then shows the sign-in form, and /api/health tells the real story).
export async function currentUser(): Promise<User | null> {
  const raw = await sessionCookieValue();
  if (!raw) return null;
  try {
    return await readSession(pool, raw);
  } catch (err) {
    console.error(`auth: session check failed: ${(err as Error).message}`);
    return null;
  }
}

// requireUser: the first line of every page behind sign-in. Checked on the server for each
// request, next to the data it protects (no proxy.ts: its checks can only be optimistic).
export async function requireUser(): Promise<User> {
  const user = await currentUser();
  if (!user) redirect("/");
  return user;
}

export const config = () => readConfig();

// respond -> a 303 with a relative Location (and the cookie, if any), or a bare status.
export function respond(a: Answer): Response {
  const headers = new Headers({ "Cache-Control": "no-store" });
  if (a.location) headers.set("Location", a.location);
  if (a.cookie) headers.append("Set-Cookie", a.cookie);
  return new Response(a.status === 403 ? "Forbidden: this form must be sent from the site itself.\n" : null, { status: a.status, headers });
}

const MAX_FORM = 4096;

// formOf -> the posted form (the pages' forms are urlencoded), or null when the body is
// anything else or larger than 4 KB; the body is read only up to that limit.
export async function formOf(req: Request): Promise<URLSearchParams | null> {
  if (!(req.headers.get("content-type") ?? "").startsWith("application/x-www-form-urlencoded")) return null;
  if (Number(req.headers.get("content-length") ?? 0) > MAX_FORM) return null;
  const reader = req.body?.getReader();
  if (!reader) return new URLSearchParams();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_FORM) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } catch {
    return null;
  }
  return new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
}
