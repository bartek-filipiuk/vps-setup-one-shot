import { pool } from "@/lib/db";
import { WaitlistForm } from "./waitlist-form";

// Rendered per request: the count comes from Postgres, not from build time.
export const dynamic = "force-dynamic";

// Coolify sets SOURCE_COMMIT on every build; locally there is none.
const build = process.env.SOURCE_COMMIT?.slice(0, 7) ?? "local";

async function waitlistCount(): Promise<number | null> {
  try {
    const { rows } = await pool.query<{ n: number }>("select count(*)::int as n from waitlist");
    return rows[0].n;
  } catch {
    return null; // DB down: the page still renders, /api/health tells the real story.
  }
}

export default async function Home() {
  const count = await waitlistCount();

  return (
    <main>
      <section className="pitch">
        <h1 className="reveal" style={{ "--i": 0 } as React.CSSProperties}>
          One prompt.
          <br />
          <em>Your own</em> deploy server.
        </h1>
        <p className="lede reveal" style={{ "--i": 1 } as React.CSSProperties}>
          Clone a repo, tell your AI coding agent to read <code>SETUP.md</code>, and an hour later you have a
          Hetzner VPS running Coolify with HTTPS, Postgres and push-to-deploy from GitHub. About 5 € a month,
          on a box you control.
        </p>
        <p className="prompt reveal" style={{ "--i": 2 } as React.CSSProperties}>
          <span aria-hidden="true">›</span> Read SETUP.md and guide me through it.
        </p>

        <div className="reveal" style={{ "--i": 3 } as React.CSSProperties}>
          <h2>Get the boilerplate. Free, when it ships.</h2>
          <WaitlistForm />
          <p className="proof">
            {count !== null && (
              <>
                <strong>{count}</strong> {count === 1 ? "person" : "people"} on the list ·{" "}
              </>
            )}
            served by the setup itself, build <code>{build}</code>
          </p>
        </div>
      </section>

      <aside className="ledger reveal" style={{ "--i": 4 } as React.CSSProperties}>
        <h2>What you get</h2>
        <dl>
          <dt>The guide</dt>
          <dd>
            <code>SETUP.md</code> and seven short phases your agent follows: server, hardening, Coolify, domain,
            database, app, handover. It checks the real server state instead of trusting its own memory.
          </dd>
          <dt>The starter</dt>
          <dd>
            This page. Next.js 16, Postgres 17, health checks, migrations on boot, a 230 MB non-root image.
            Replace the copy, keep the plumbing.
          </dd>
          <dt>The updates</dt>
          <dd>
            Coolify changes. When a step breaks, the guide gets fixed and you get one mail. That is the whole
            reason for the list.
          </dd>
        </dl>
      </aside>

      <footer>
        <a href="https://devince.dev">devince.dev</a> · <a href="/api/health">health check</a>
      </footer>
    </main>
  );
}
