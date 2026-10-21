import { Pool } from "pg";

// One pool per process; the global survives dev hot reloads.
const globalForDb = globalThis as unknown as { pool?: Pool };

export const pool =
  globalForDb.pool ??
  new Pool({ connectionString: process.env.DATABASE_URL, max: 5, connectionTimeoutMillis: 5000 });

if (!globalForDb.pool) {
  // An idle client that loses its connection (the database restarts) emits "error" on the
  // pool; without a listener that would crash the process instead of failing the next query.
  pool.on("error", (err) => console.error(`db: idle client error: ${err.message}`));
}
globalForDb.pool = pool;

// ponytail: idempotent bootstrap SQL run at server start (instrumentation.ts), additive only.
// Swap for a real migration tool (drizzle-kit, node-pg-migrate) once the schema grows.
// Tokens and sessions are stored as sha256 hashes; the raw values exist only in the mail link
// and the cookie.
export const SCHEMA = `
  create table if not exists users (
    id bigint generated always as identity primary key,
    email text not null unique check (length(email) <= 254),
    created_at timestamptz not null default now(),
    last_login_at timestamptz
  );
  create table if not exists login_tokens (
    token_hash text primary key,
    email text not null check (length(email) <= 254),
    created_at timestamptz not null default now(),
    expires_at timestamptz not null,
    used_at timestamptz,
    request_ip text
  );
  create table if not exists sessions (
    token_hash text primary key,
    user_id bigint not null references users (id) on delete cascade,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null,
    last_seen_at timestamptz not null default now()
  );
  create index if not exists sessions_user_idx on sessions (user_id);
  create table if not exists auth_rate (
    key text not null,
    window_start timestamptz not null,
    hits int not null default 1,
    primary key (key, window_start)
  );
`;

// Any constant: the key of the advisory lock that serialises the schema SQL.
const MIGRATE_LOCK = 7242400224;

// The schema in one transaction under a transaction-level advisory lock, so two containers
// starting together (a rolling deploy) never race on "create table if not exists"
// (starter-worker/src/db.js does the same).
export async function migrate() {
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query("select pg_advisory_xact_lock($1)", [MIGRATE_LOCK]);
    await c.query(SCHEMA);
    await c.query("commit");
  } catch (err) {
    await c.query("rollback").catch(() => {});
    throw err;
  } finally {
    c.release();
  }
}

// The DB may still be booting (server reboot, first deploy), so retry briefly.
// Next.js swallows errors thrown from instrumentation, so exit explicitly: the
// container restarts instead of serving traffic without a schema.
export async function migrateOrExit(attempts = 10, delayMs = 3000) {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      await migrate();
      console.log("db: schema ready");
      return;
    } catch (err) {
      console.error(`db: migrate attempt ${attempt}/${attempts} failed: ${(err as Error).message}`);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  process.exit(1);
}
