// The health answer: exactly two keys, the shape test/fixtures.sh and Coolify rely on.
import test from "node:test";
import assert from "node:assert/strict";
import { healthAnswer } from "../lib/health.ts";
import { fakeDb, logger, rows } from "./fake-db.ts";

test("health: 200 ok/ok when the schema answers", async () => {
  const db = fakeDb(rows({ "?column?": 1 }));
  assert.deepEqual(await healthAnswer(db, logger()), { code: 200, body: { status: "ok", db: "ok" } });
  assert.equal(db.calls[0].text, "select 1 from users limit 1");
});

test("health: 503 error/error without details when the database fails", async () => {
  const log = logger();
  const a = await healthAnswer(fakeDb(new Error('relation "users" does not exist')), log);
  assert.deepEqual(a, { code: 503, body: { status: "error", db: "error" } });
  assert.deepEqual(Object.keys(a.body).sort(), ["db", "status"]);
  assert.match(log.lines[0], /^health: db check failed: relation "users" does not exist$/);
});
