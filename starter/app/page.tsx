import { pool } from "@/lib/db";
import { CopyButton } from "./copy-button";
import { WaitlistForm } from "./waitlist-form";

// Rendered per request: the count comes from Postgres, not from build time.
export const dynamic = "force-dynamic";

// Coolify sets SOURCE_COMMIT on every build; locally there is none.
const build = process.env.SOURCE_COMMIT?.slice(0, 7) ?? "local";

const COMMAND =
  'git clone https://github.com/bartek-filipiuk/vps-setup-one-shot.git && cd vps-setup-one-shot && claude "Read SETUP.md and guide me through it."';

const steps: { title: string; what: string; you: string }[] = [
  {
    title: "Check your machine",
    what: "The agent checks git, GitHub login and your SSH key, then asks a few questions once: provider, domain, app name.",
    you: "Answer five questions.",
  },
  {
    title: "Rent the server",
    what: "A 4 GB Hetzner VPS with a cloud firewall that only lets in SSH and web traffic. About 5 € a month, billed by the hour.",
    you: "Create a Hetzner API token and add two DNS records.",
  },
  {
    title: "Lock it down",
    what: "System updates, automatic security updates, swap for builds, and SSH that accepts only your key.",
    you: "Nothing.",
  },
  {
    title: "Install Coolify",
    what: "The open-source panel that builds and runs your apps. It is never reachable from the internet before it is secured.",
    you: "Create the admin account through a private SSH tunnel.",
  },
  {
    title: "Domain and HTTPS",
    what: "Coolify gets its own domain with a certificate, and the agent gets API access.",
    you: "Create an API token and type it into your own terminal. Never into the chat.",
  },
  {
    title: "Ship the starter",
    what: "A private GitHub repo, Postgres 17, this app on your domain, and a webhook so every push to main deploys. Each step is proven with real output.",
    you: "Sign up on your own page and watch the counter move.",
  },
  {
    title: "Handover",
    what: "Backups, a one-page summary of your server, and the exact commands to tear everything down when you are done.",
    you: "Decide on backups.",
  },
];

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
          One command.
          <br />
          <em>Your own</em> deploy server.
        </h1>
        <p className="lede reveal" style={{ "--i": 1 } as React.CSSProperties}>
          Paste one line into your terminal. Your AI coding agent takes it from there: a Hetzner VPS running
          Coolify with HTTPS, Postgres and push-to-deploy from GitHub, in about an hour, on a box you control.
        </p>

        <div className="command reveal" style={{ "--i": 2 } as React.CSSProperties}>
          <pre>
            <code>{COMMAND}</code>
          </pre>
          <CopyButton text={COMMAND} />
        </div>
        <p className="aside reveal" style={{ "--i": 2 } as React.CSSProperties}>
          Works with Claude Code. Any agent that can read a file and run commands can follow the same guide.
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
            <code>SETUP.md</code> and seven short phases your agent follows. It checks the real server state
            instead of trusting its own memory, so you can stop and resume with the same command.
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

      <section className="steps reveal" style={{ "--i": 5 } as React.CSSProperties}>
        <h2>What happens, step by step</h2>
        <p className="lede">
          The agent does everything that has a command or an API. You do only what has neither: accounts,
          payment, DNS, and typing secrets into your own terminal.
        </p>
        <ol>
          {steps.map((s) => (
            <li key={s.title}>
              <h3>{s.title}</h3>
              <p>{s.what}</p>
              <p className="you">
                <span>You:</span> {s.you}
              </p>
            </li>
          ))}
        </ol>
      </section>

      <footer>
        <a href="https://devince.dev">devince.dev</a> · <a href="/api/health">health check</a>
      </footer>
    </main>
  );
}
