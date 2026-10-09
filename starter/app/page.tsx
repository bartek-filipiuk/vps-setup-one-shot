import { pool } from "@/lib/db";
import { CopyButton } from "./copy-button";
import { Corners } from "./corners";
import { WaitlistForm } from "./waitlist-form";

// Rendered per request: the count comes from Postgres, not from build time.
export const dynamic = "force-dynamic";

const REPO = "https://github.com/bartek-filipiuk/vps-setup-one-shot";
const COMMAND = `git clone ${REPO}.git && cd vps-setup-one-shot && claude "Read SETUP.md and guide me through it."`;

// Coolify sets SOURCE_COMMIT on every build; locally there is none.
const commit = process.env.SOURCE_COMMIT;
const sha = commit?.slice(0, 7) ?? "local";
const Sha = () => (commit ? <a href={`${REPO}/commit/${commit}`} className="sha">{sha}</a> : <span className="sha">{sha}</span>);

const steps: { title: string; what: string; you: string }[] = [
  { title: "Check your machine", what: "The agent checks git, your GitHub login and your SSH key, then asks five questions once.", you: "Answer them." },
  { title: "Rent the server", what: "A 4 GB Hetzner VPS behind a cloud firewall with only SSH and web open. About 5 EUR a month, billed hourly.", you: "Create a Hetzner API token and add two DNS records." },
  { title: "Lock it down", what: "System updates, automatic security updates, swap, and key-only SSH.", you: "Nothing." },
  { title: "Install Coolify", what: "The open-source panel that builds and runs your apps. It is never reachable from the internet before it is secured.", you: "Create the admin account through a private SSH tunnel." },
  { title: "Domain and HTTPS", what: "Coolify gets its own domain with a certificate, and the agent gets API access.", you: "Create an API token and type it into your own terminal, never into the chat." },
  { title: "Ship the starter", what: "A private GitHub repo, Postgres 17, the app on your domain, and a webhook so every push to main deploys. Each step is proven with real output.", you: "Sign up on your own page and watch the counter move." },
  { title: "Handover", what: "Backups, a one-page summary of your server, and the exact commands to tear everything down.", you: "Decide on backups." },
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
    <>
      <header className="site-header">
        <nav className="nav" aria-label="Site">
          <a className="brand" href="#top">vps-setup-one-shot</a>
          <a className="live" href="/api/health">
            <span className="dot" aria-hidden="true" />
            <span>Live on this setup · build {sha}</span>
          </a>
        </nav>
      </header>

      <main className="wrap" id="top">
        <section className="hero" aria-labelledby="hero-title">
          <h1 id="hero-title">
            <span>One command.</span>
            <span><em>Your own</em> deploy server.</span>
          </h1>
          <p className="lede">
            Paste one line into your terminal. Your AI coding agent takes it from there: a Hetzner VPS running
            Coolify with HTTPS, Postgres and push-to-deploy from GitHub, in about an hour, on a box you control.
          </p>

          <div className="command blueprint" role="group" aria-label="Setup command">
            <Corners />
            <div className="command-head">
              <span className="kicker">Paste into your terminal</span>
              <CopyButton text={COMMAND} />
            </div>
            <code>
              <span className="line">
                <span className="dim sign" aria-hidden="true">$ </span>
                git clone https://github.com/<wbr />bartek-filipiuk/<wbr />vps-setup-one-shot.git <span className="dim">&amp;&amp;</span>
              </span>
              <span className="line cont">cd vps-setup-one-shot <span className="dim">&amp;&amp;</span></span>
              <span className="line cont">claude &quot;Read SETUP.md and guide me through it.&quot;</span>
            </code>
          </div>
          <p className="note">Works with Claude Code. Any agent that can read a file and run commands can follow the same guide.</p>

          <div className="signup plate blueprint">
            <Corners />
            <WaitlistForm />
            <div className="proof" aria-label="Live proof">
              <span className="kicker">
                <span className="dot" aria-hidden="true" />
                <span>Read from Postgres on this request</span>
              </span>
              <span className="count" aria-hidden="true">{count === null ? "—" : count.toLocaleString("en-US")}</span>
              <p>
                <span className="sr-only">{count === null ? "unknown number of" : count.toLocaleString("en-US")} </span>
                people on the list · served by the setup itself, build <Sha />
              </p>
            </div>
          </div>
        </section>

        <section className="block" aria-labelledby="get-title">
          <h2 id="get-title">What you get</h2>
          <div className="get plate blueprint">
            <Corners />
            <article>
              <h3>The guide</h3>
              <p>
                <code className="file">SETUP.md</code> and seven short phases the agent follows. It checks the real server
                state instead of trusting its own memory, so you can stop at any point and resume with the same command.
              </p>
            </article>
            <article>
              <h3>The starter</h3>
              <p>This page. Next.js 16, Postgres 17, health checks, migrations on boot, a 230 MB non-root image. Replace the copy, keep the plumbing.</p>
            </article>
            <article>
              <h3>The updates</h3>
              <p>Coolify changes. When a step breaks, the guide gets fixed and you get one mail. That is the whole reason for the list.</p>
            </article>
          </div>
        </section>

        <section className="block" aria-labelledby="steps-title">
          <h2 id="steps-title">What happens, step by step</h2>
          <p className="intro">
            The agent does everything that has a command or an API. You do only what has neither: accounts, payment,
            DNS, and typing secrets into your own terminal.
          </p>
          <ol className="steps">
            {steps.map((s, i) => (
              <li key={s.title}>
                <span className="num" aria-hidden="true">{i + 1}</span>
                <div className="step-body">
                  <div className="step-main">
                    <h3>{s.title}</h3>
                    <p>{s.what}</p>
                  </div>
                  <p className={s.you === "Nothing." ? "you none" : "you"}>
                    <b>You:</b>{s.you}
                  </p>
                </div>
              </li>
            ))}
          </ol>
        </section>

        <section className="block trust" aria-label="What you can rely on">
          <div className="plate blueprint">
            <Corners />
            <ul>
              <li>Secrets never pass through the chat window.</li>
              <li>Every step is verified against the real server, not the agent&apos;s memory.</li>
              <li>You can delete the server any time; billing stops.</li>
            </ul>
          </div>
        </section>
      </main>

      <footer className="site-footer">
        <div className="foot">
          <span>Made by <a href="https://devince.dev">devince.dev</a></span>
          <a className="live" href="/api/health">
            <span className="dot" aria-hidden="true" />
            <span>Health check: /api/health</span>
          </a>
          <span className="right">Deployed commit <Sha /></span>
        </div>
      </footer>
    </>
  );
}
