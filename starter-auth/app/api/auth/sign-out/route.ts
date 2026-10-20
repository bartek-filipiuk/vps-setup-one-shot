import { cookies } from "next/headers";
import { pool } from "@/lib/db.ts";
import { formOf, config, respond } from "@/lib/auth.ts";
import { COOKIE, handleSignOut } from "@/lib/auth-core.ts";

export const dynamic = "force-dynamic";

// POST (everywhere=1 for every device) -> 303 to / with the cookie cleared; 403 from another site.
export async function POST(req: Request) {
  const form = await formOf(req);
  const answer = await handleSignOut(
    pool,
    {
      origin: req.headers.get("origin"),
      referer: req.headers.get("referer"),
      session: (await cookies()).get(COOKIE)?.value,
      everywhere: form?.get("everywhere") === "1",
    },
    config().siteUrl,
  );
  return respond(answer);
}
