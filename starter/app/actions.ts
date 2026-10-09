"use server";

import { revalidatePath } from "next/cache";
import { pool } from "@/lib/db";

export type JoinState = { ok: boolean; message: string } | null;

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export async function joinWaitlist(_prev: JoinState, form: FormData): Promise<JoinState> {
  // Honeypot: real people never see this field, simple bots fill it.
  if (form.get("company")) return { ok: true, message: "You're on the list." };

  const email = String(form.get("email") ?? "").trim().toLowerCase();
  if (email.length > 254 || !EMAIL.test(email)) {
    return { ok: false, message: "That doesn't look like an email address. Check it and try again." };
  }

  try {
    // Unique constraint makes a double submit a no-op, and we don't reveal whether the email existed.
    await pool.query("insert into waitlist (email) values ($1) on conflict (email) do nothing", [email]);
    revalidatePath("/");
    return { ok: true, message: "You're on the list." };
  } catch (err) {
    console.error("waitlist: insert failed", err);
    return { ok: false, message: "We couldn't save that right now. Try again in a minute." };
  }
}
