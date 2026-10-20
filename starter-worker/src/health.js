// GET /api/health, the same contract as the starter and the fixtures: 200
// {"status":"ok","db":"ok"} when the database answers and the loop is alive, 503
// {"status":"error","db":"error"} when the database does not answer, 503
// {"status":"error","db":"ok"} when the database is fine but the loop has not ticked for
// staleMs (stuck). No error details. No domain: only Coolify's and Docker's checks call it.
import http from "node:http";

const TIMEOUT_MS = 3000;

function withTimeout(promise, ms) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("timeout")), ms); }),
  ]).finally(() => clearTimeout(timer));
}

export async function healthAnswer(db, state, staleMs, now = Date.now()) {
  try {
    await withTimeout(db.query("select 1 from jobs limit 1"), TIMEOUT_MS);
  } catch (err) {
    console.error(`health: db check failed: ${err.message}`);
    return { code: 503, body: { status: "error", db: "error" } };
  }
  if (now - state.lastTick > staleMs) {
    console.error(`health: the loop has not ticked for ${Math.round((now - state.lastTick) / 1000)} s`);
    return { code: 503, body: { status: "error", db: "ok" } };
  }
  return { code: 200, body: { status: "ok", db: "ok" } };
}

export function createHealthServer(db, state, staleMs) {
  return http.createServer(async (req, res) => {
    const path = (req.url ?? "").split("?")[0];
    if (req.method !== "GET" || path !== "/api/health") {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end('{"error":"not found"}');
      return;
    }
    const a = await healthAnswer(db, state, staleMs);
    res.writeHead(a.code, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    res.end(JSON.stringify(a.body));
  });
}
