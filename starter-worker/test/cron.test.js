import test from "node:test";
import assert from "node:assert/strict";
import { dueSlot, SCHEDULES, tick, validateSchedules } from "../src/cron.js";
import { HANDLERS } from "../src/jobs.js";

test("the shipped schedules are valid and use known job kinds", () => {
  assert.equal(validateSchedules(SCHEDULES, Object.keys(HANDLERS)), true);
  assert.deepEqual(SCHEDULES.map((s) => s.name), ["heartbeat", "prune"]);
});

test("validateSchedules refuses bad lists", () => {
  const ok = { name: "a", everySeconds: 60, kind: "echo", payload: {} };
  const kinds = ["echo"];
  assert.throws(() => validateSchedules([ok, ok], kinds), /listed twice/);
  assert.throws(() => validateSchedules([{ ...ok, everySeconds: 59 }], kinds), /everySeconds/);
  assert.throws(() => validateSchedules([{ ...ok, everySeconds: 90.5 }], kinds), /everySeconds/);
  assert.throws(() => validateSchedules([{ ...ok, kind: "mail" }], kinds), /no handler for job kind 'mail'/);
  assert.throws(() => validateSchedules([{ ...ok, name: "Bad Name" }], kinds), /not valid/);
  assert.throws(() => validateSchedules([{ ...ok, payload: [] }], kinds), /payload must be an object/);
});

test("dueSlot: slot starts aligned to the epoch, stable inside a slot, next at the boundary", () => {
  const five = { everySeconds: 300 };
  assert.equal(dueSlot(five, new Date("2026-10-20T10:04:59.999Z")).toISOString(), "2026-10-20T10:00:00.000Z");
  assert.equal(dueSlot(five, new Date("2026-10-20T10:00:00.000Z")).toISOString(), "2026-10-20T10:00:00.000Z");
  assert.equal(dueSlot(five, new Date("2026-10-20T10:05:00.000Z")).toISOString(), "2026-10-20T10:05:00.000Z");
  const day = { everySeconds: 86400 };
  assert.equal(dueSlot(day, new Date("2026-10-20T23:59:59Z")).toISOString(), "2026-10-20T00:00:00.000Z");
  assert.equal(dueSlot(day, new Date("2026-10-21T00:00:01Z")).toISOString(), "2026-10-21T00:00:00.000Z");
});

test("tick: one statement per schedule, the job only when the slot insert wins", async () => {
  const calls = [];
  const answers = [{ rowCount: 1 }, { rowCount: 0 }];
  const db = { async query(text, values) { calls.push({ text: text.replace(/\s+/g, " ").trim(), values }); return answers.shift(); } };
  const fired = await tick(db, new Date("2026-10-20T10:03:00Z"));
  assert.deepEqual(fired, ["heartbeat"]);
  assert.equal(calls.length, 2);
  assert.match(calls[0].text, /^with slot as \(insert into cron_runs \(name, due_at\) values \(\$1, \$2\) on conflict do nothing returning name\) insert into jobs \(kind, payload\) select \$3, \$4::jsonb from slot returning id$/);
  assert.deepEqual(calls[0].values, ["heartbeat", "2026-10-20T10:00:00.000Z", "echo", '{"from":"cron"}']);
  assert.deepEqual(calls[1].values, ["prune", "2026-10-20T00:00:00.000Z", "prune", "{}"]);
});
