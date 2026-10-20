import { pool } from "@/lib/db.ts";
import { formOf, config, respond } from "@/lib/auth.ts";
import { handleCallback } from "@/lib/auth-core.ts";

export const dynamic = "force-dynamic";

// POST token (from the confirm page /auth/callback) -> 303 to /account with the session
// cookie, or to /?error=expired; 403 from another site.
export async function POST(req: Request) {
  const form = await formOf(req);
  const answer = await handleCallback(
    pool,
    { origin: req.headers.get("origin"), referer: req.headers.get("referer"), token: form?.get("token") },
    config().siteUrl,
  );
  return respond(answer);
}
