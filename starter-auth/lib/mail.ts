// Transactional mail over SMTP (nodemailer), or with MAIL_LOG=1 into the log only (nodemailer's
// JSON transport: no network). One transport per process, made on the first mail.
import { createHash } from "node:crypto";
import nodemailer from "nodemailer";
import type { Transporter } from "nodemailer";
import type { MailSettings } from "./config.ts";
import type { Mail } from "./auth-core.ts";

let cached: { key: string; t: Transporter } | null = null;

// transportOptions -> what nodemailer gets. smtp:// must upgrade to TLS (requireTLS), so a
// password is never sent in clear; a 10-second connect timeout instead of the default two minutes.
export function transportOptions(m: MailSettings) {
  if (m.mode === "log") return { jsonTransport: true as const };
  return {
    host: m.host,
    port: m.port,
    secure: m.secure,
    requireTLS: !m.secure,
    auth: { user: m.user, pass: m.pass },
    connectionTimeout: 10_000,
    greetingTimeout: 10_000,
    socketTimeout: 20_000,
  };
}

// transportKey -> what the cached transport is reused for: a sha256 over every SMTP_URL part
// (the password too, so a rotated SMTP_URL gets a new transport) and never the raw values.
export function transportKey(m: MailSettings): string {
  if (m.mode === "log") return "log";
  return `smtp:${createHash("sha256").update(JSON.stringify([m.host, m.port, m.secure, m.user, m.pass])).digest("hex")}`;
}

function transport(m: MailSettings): Transporter {
  const key = transportKey(m);
  if (!cached || cached.key !== key) cached = { key, t: nodemailer.createTransport(transportOptions(m)) };
  return cached.t;
}

// sendMail: in log mode prints one line `mail: {"to":...,"subject":...,"text":...}` (the sign-in
// link included; that is the point of the mode); over SMTP only the message id is logged.
export async function sendMail(m: MailSettings, mail: Mail, log: { log(s: string): void } = console): Promise<void> {
  const info = await transport(m).sendMail({ from: m.from, to: { name: "", address: mail.to }, subject: mail.subject, text: mail.text, html: mail.html });
  if (m.mode === "log") {
    log.log(`mail: ${JSON.stringify({ to: mail.to, subject: mail.subject, text: mail.text })}`);
  } else {
    log.log(`mail: sent ${info.messageId}`);
  }
}
