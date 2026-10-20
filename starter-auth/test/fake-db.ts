// fakeDb ANSWERS -> a database that records every query and answers each with the next answer
// (an object, or an Error to throw); the pattern of starter-worker/test/queue.test.js.
import type { Db } from "../lib/auth-core.ts";

export type Call = { text: string; values: unknown[] };
type Answer = { rows: any[]; rowCount: number | null } | Error;

export function fakeDb(...answers: Answer[]): Db & { calls: Call[] } {
  const calls: Call[] = [];
  return {
    calls,
    async query(text: string, values: unknown[] = []) {
      calls.push({ text: text.replace(/\s+/g, " ").trim(), values });
      const a = answers.length ? answers.shift()! : { rows: [], rowCount: 0 };
      if (a instanceof Error) throw a;
      return a;
    },
  };
}

export const rows = (...r: any[]) => ({ rows: r, rowCount: r.length });
// logger -> a log that keeps its lines, for the assertions about what is (never) logged.
export function logger() {
  const lines: string[] = [];
  return { lines, log: (s: string) => { lines.push(s); }, error: (s: string) => { lines.push(s); } };
}
