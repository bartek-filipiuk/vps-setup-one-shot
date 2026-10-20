import { pool } from "@/lib/db.ts";
import { healthAnswer } from "@/lib/health.ts";

export const dynamic = "force-dynamic";

// Used by the setup's smoke test and by Coolify's health check.
export async function GET() {
  const a = await healthAnswer(pool);
  return Response.json(a.body, { status: a.code });
}
