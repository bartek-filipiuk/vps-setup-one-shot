// In-process schedules, one way: every tick claims the current slot of each schedule in
// cron_runs (primary key name + due_at) and, only when the insert wins, enqueues the job in the
// same statement. Two containers alive at once (a rolling deploy) enqueue each slot once, and
// the queue stays the only way a job runs. Slots are aligned to the Unix epoch (UTC): a daily
// schedule is due at 00:00 UTC. No cron expressions: "every N seconds" is enough here.
import { validKind } from "./queue.js";

export const SCHEDULES = [
  { name: "heartbeat", everySeconds: 300, kind: "echo", payload: { from: "cron" } },
  { name: "prune", everySeconds: 86400, kind: "prune", payload: {} },
];

// validateSchedules LIST KINDS -> throws on a bad list: unique names, an interval of at least
// 60 s (whole seconds), a known job kind, an object payload.
export function validateSchedules(list, kinds) {
  const seen = new Set();
  for (const s of list) {
    if (!validKind(s.name)) throw new Error(`schedule name '${s.name}' is not valid`);
    if (seen.has(s.name)) throw new Error(`schedule '${s.name}' is listed twice`);
    seen.add(s.name);
    if (!Number.isInteger(s.everySeconds) || s.everySeconds < 60) throw new Error(`schedule '${s.name}': everySeconds must be a whole number >= 60`);
    if (!kinds.includes(s.kind)) throw new Error(`schedule '${s.name}': no handler for job kind '${s.kind}'`);
    if (s.payload === null || typeof s.payload !== "object" || Array.isArray(s.payload)) throw new Error(`schedule '${s.name}': payload must be an object`);
  }
  return true;
}

// dueSlot SCHEDULE NOW -> the start of the slot NOW falls in, as a Date.
export function dueSlot(schedule, now) {
  const ms = schedule.everySeconds * 1000;
  return new Date(Math.floor(now.getTime() / ms) * ms);
}

// tick DB NOW -> enqueues the job of every schedule whose current slot nobody claimed yet;
// returns the names of the schedules that enqueued.
export async function tick(db, now = new Date(), schedules = SCHEDULES) {
  const fired = [];
  for (const s of schedules) {
    const r = await db.query(
      `with slot as (insert into cron_runs (name, due_at) values ($1, $2) on conflict do nothing returning name)
       insert into jobs (kind, payload) select $3, $4::jsonb from slot returning id`,
      [s.name, dueSlot(s, now).toISOString(), s.kind, JSON.stringify(s.payload)],
    );
    if (r.rowCount > 0) fired.push(s.name);
  }
  return fired;
}
