"use server";

import { revalidatePath } from "next/cache";
import { headers } from "next/headers";
import { pool } from "@/lib/db";
import { copy, type Lang, type Status } from "./copy";

export type JoinState = { ok: boolean; status: Status } | null;

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// ponytail: per-process fixed window, enough for one container. Move to Postgres if the app scales out.
const WINDOW_MS = 10 * 60 * 1000;
const hits = new Map<string, { n: number; until: number }>();
function limited(ip: string, max = 5): boolean {
  const now = Date.now();
  if (hits.size > 10_000) hits.clear(); // bound memory under a flood
  const h = hits.get(ip);
  if (!h || h.until < now) {
    hits.set(ip, { n: 1, until: now + WINDOW_MS });
    return false;
  }
  return ++h.n > max;
}

// Brevo is optional: with these env vars unset the starter only writes to Postgres.
function brevo(lang: Lang) {
  const suffix = lang.toUpperCase();
  const key = process.env.BREVO_API_KEY;
  const list = Number(process.env[`BREVO_LIST_${suffix}`]);
  const template = Number(process.env[`BREVO_DOI_TEMPLATE_${suffix}`]);
  const site = process.env.SITE_URL;
  return key && list && template && site ? { key, list, template, site } : null;
}

// Double opt-in: Brevo mails a confirmation link and adds the contact to the list only after the click.
async function sendDoubleOptIn(email: string, lang: Lang, cfg: NonNullable<ReturnType<typeof brevo>>) {
  const res = await fetch("https://api.brevo.com/v3/contacts/doubleOptinConfirmation", {
    method: "POST",
    headers: { "api-key": cfg.key, "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      email,
      includeListIds: [cfg.list],
      templateId: cfg.template,
      redirectionUrl: new URL(copy[lang].confirmed.path, cfg.site).href,
    }),
    signal: AbortSignal.timeout(10_000),
  });
  if (res.ok) return;
  const body = await res.text();
  if (body.includes("duplicate_parameter")) return; // already a contact: same answer as a new one
  throw new Error(`brevo ${res.status}: ${body.slice(0, 300)}`);
}

export async function joinWaitlist(_prev: JoinState, form: FormData): Promise<JoinState> {
  const lang: Lang = form.get("lang") === "pl" ? "pl" : "en";
  const cfg = brevo(lang);
  const done: JoinState = { ok: true, status: cfg ? "confirm" : "joined" };

  // Honeypot: real people never see this field, simple bots fill it.
  if (form.get("company")) return done;

  const email = String(form.get("email") ?? "").trim().toLowerCase();
  if (email.length > 254 || !EMAIL.test(email)) return { ok: false, status: "invalid" };
  if (form.get("consent") !== "on") return { ok: false, status: "consent" };

  // The last X-Forwarded-For entry is the one Traefik (Coolify's proxy) appended; earlier ones come from the client.
  const ip = (await headers()).get("x-forwarded-for")?.split(",").at(-1)?.trim() || "unknown";
  if (limited(ip)) return { ok: false, status: "busy" };

  try {
    // Unique constraint makes a double submit a no-op, and we don't reveal whether the email existed.
    const { rows } = await pool.query<{ id: string }>(
      "insert into waitlist (email) values ($1) on conflict (email) do nothing returning id",
      [email],
    );
    // Only a new row triggers a confirmation mail, so nobody can flood one inbox through this form.
    if (cfg && rows[0]) {
      try {
        await sendDoubleOptIn(email, lang, cfg);
      } catch (err) {
        // Undo the row so a retry sends the mail again instead of hitting "already exists".
        await pool.query("delete from waitlist where id = $1", [rows[0].id]);
        throw err;
      }
    }
    revalidatePath("/");
    revalidatePath("/pl");
    return done;
  } catch (err) {
    console.error("waitlist: signup failed", err);
    return { ok: false, status: "failed" };
  }
}
