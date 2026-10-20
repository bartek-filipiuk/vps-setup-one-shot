// The worker's tables live in the web app's Postgres (the same DATABASE_URL): one database,
// one dump before every deploy of either app, one backup.
import pg from "pg";

export const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  max: 3,
  connectionTimeoutMillis: 5000,
});

// An idle client that loses its connection (the database restarts) emits "error" on the pool;
// without a listener that would crash the process instead of failing the next query.
pool.on("error", (err) => console.error(`db: idle client error: ${err.message}`));

// ponytail: idempotent bootstrap SQL run at start, like starter/lib/db.ts.
// Swap for a real migration tool once the schema grows.
export const SCHEMA = `
  create table if not exists jobs (
    id bigint generated always as identity primary key,
    kind text not null check (length(kind) between 1 and 100),
    payload jsonb not null default '{}'::jsonb,
    status text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed')),
    run_at timestamptz not null default now(),
    attempts int not null default 0,
    max_attempts int not null default 5 check (max_attempts between 1 and 100),
    locked_at timestamptz,
    last_error text,
    created_at timestamptz not null default now(),
    finished_at timestamptz
  );
  create index if not exists jobs_queued_idx on jobs (run_at, id) where status = 'queued';
  create table if not exists cron_runs (
    name text not null,
    due_at timestamptz not null,
    primary key (name, due_at)
  );
`;

export async function migrate(db = pool) {
  await db.query(SCHEMA);
}

// The database may still be booting (server reboot, first deploy), so retry briefly, then
// exit: the container restarts instead of running without a schema (starter/lib/db.ts).
export async function migrateOrExit(attempts = 10, delayMs = 3000) {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      await migrate();
      console.log("db: schema ready");
      return;
    } catch (err) {
      console.error(`db: migrate attempt ${attempt}/${attempts} failed: ${err.message}`);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  process.exit(1);
}
