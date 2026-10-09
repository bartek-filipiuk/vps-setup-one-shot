import { pool } from "@/lib/db";

export const dynamic = "force-dynamic";

// Used by the setup's smoke test and by Coolify's health check.
export async function GET() {
  try {
    await pool.query("select 1 from waitlist limit 1"); // schema exists, not just a connection
    return Response.json({ status: "ok", db: "ok" });
  } catch (err) {
    console.error("health: db check failed", err);
    // No error details in the response: it is public.
    return Response.json({ status: "error", db: "error" }, { status: 503 });
  }
}
