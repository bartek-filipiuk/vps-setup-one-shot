import { Pool } from "pg";

// One pool per process; the global survives dev hot reloads.
const globalForDb = globalThis as unknown as { pool?: Pool };

export const pool =
  globalForDb.pool ??
  new Pool({ connectionString: process.env.DATABASE_URL, max: 5 });

globalForDb.pool = pool;

// ponytail: idempotent bootstrap SQL run at server start (instrumentation.ts).
// Swap for a real migration tool (drizzle-kit, node-pg-migrate) once the schema grows.
export async function migrate() {
  await pool.query(`
    create table if not exists waitlist (
      id bigint generated always as identity primary key,
      email text not null unique check (length(email) <= 254),
      created_at timestamptz not null default now()
    )
  `);
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
