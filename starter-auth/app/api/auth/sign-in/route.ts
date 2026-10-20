import { pool } from "@/lib/db.ts";
import { formOf, config, respond } from "@/lib/auth.ts";
import { handleSignIn, LINK_MINUTES } from "@/lib/auth-core.ts";
import { sendMail } from "@/lib/mail.ts";
import { signInMail } from "@/lib/mail-templates.ts";

export const dynamic = "force-dynamic";

// POST email (form-encoded) -> 303 to /?sent=1, or /?error=invalid|busy|failed; 403 from another site.
export async function POST(req: Request) {
  const form = await formOf(req);
  if (!form) return respond({ status: 303, location: "/?error=invalid" });
  const c = config();
  const answer = await handleSignIn(
    pool,
    {
      origin: req.headers.get("origin"),
      referer: req.headers.get("referer"),
      xff: req.headers.get("x-forwarded-for"),
      email: form.get("email"),
      company: form.get("company"),
    },
    c,
    (mail) => sendMail(c.mail, mail),
    (link) => signInMail({ appName: c.appName, link, minutes: LINK_MINUTES }),
  );
  return respond(answer);
}
