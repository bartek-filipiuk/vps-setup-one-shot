// GET /api/health, the contract of every app of this setup: 200 {"status":"ok","db":"ok"} when
// the schema answers, 503 {"status":"error","db":"error"} otherwise, no error details (it is
// public). Mail is not part of it: an SMTP outage must not roll back a deploy or mark the app down.
import type { Db } from "./auth-core.ts";

const TIMEOUT_MS = 3000;

export async function healthAnswer(db: Db, log: { error(s: string): void } = console) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      db.query("select 1 from users limit 1"), // schema exists, not just a connection
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("timeout")), TIMEOUT_MS); }),
    ]);
    return { code: 200, body: { status: "ok", db: "ok" } };
  } catch (err) {
    log.error(`health: db check failed: ${(err as Error).message}`);
    return { code: 503, body: { status: "error", db: "error" } };
  } finally {
    clearTimeout(timer);
  }
}
