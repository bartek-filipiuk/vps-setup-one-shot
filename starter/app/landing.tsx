import { pool } from "@/lib/db";
import { CopyButton } from "./copy-button";
import { copy, type Lang } from "./copy";
import { Corners } from "./corners";
import { WaitlistForm } from "./waitlist-form";

const REPO = "https://github.com/bartek-filipiuk/vps-setup-one-shot";
const COMMAND = `git clone ${REPO}.git && cd vps-setup-one-shot && claude "Read SETUP.md and guide me through it."`;

// Coolify sets SOURCE_COMMIT on every build; locally there is none.
const commit = process.env.SOURCE_COMMIT;
const sha = commit?.slice(0, 7) ?? "local";
const Sha = () => (commit ? <a href={`${REPO}/commit/${commit}`} className="sha">{sha}</a> : <span className="sha">{sha}</span>);

async function waitlistCount(): Promise<number | null> {
  try {
    const { rows } = await pool.query<{ n: number }>("select count(*)::int as n from waitlist");
    return rows[0].n;
  } catch {
    return null; // DB down: the page still renders, /api/health tells the real story.
  }
}

// otherPath: where the language switch goes; defaults to the other language's home.
export function Header({ lang, otherPath, current }: { lang: Lang; otherPath?: string; current?: "roadmap" }) {
  const t = copy[lang];
  return (
    <header className="site-header">
      <nav className="nav" aria-label="Site">
        <a className="brand" href={t.path}>vps-setup-one-shot</a>
        <a className="navlink" href={t.roadmap.path} aria-current={current === "roadmap" ? "page" : undefined}>{t.roadmap.nav}</a>
        <a className="live" href="/api/health">
          <span className="dot" aria-hidden="true" />
          <span>{t.live} {sha}</span>
        </a>
        <a className="lang" href={otherPath ?? t.other.path} hrefLang={t.other.lang} lang={t.other.lang} aria-label={t.other.label}>
          {t.other.short}
        </a>
      </nav>
    </header>
  );
}

export function Footer({ lang }: { lang: Lang }) {
  const t = copy[lang].footer;
  return (
    <footer className="site-footer">
      <div className="foot">
        <span>{t.madeBy} <a href="https://devince.dev">devince.dev</a></span>
        <a href={REPO}>GitHub</a>
        <a href="https://youtube.com/@devins">YouTube</a>
        {t.extra && <a href={t.extra.url}>{t.extra.text}</a>}
        <a className="live" href="/api/health">
          <span className="dot" aria-hidden="true" />
          <span>{t.health}</span>
        </a>
        <span className="right">{t.deployed} <Sha /></span>
      </div>
    </footer>
  );
}

export async function Landing({ lang }: { lang: Lang }) {
  const t = copy[lang];
  const count = await waitlistCount();
  const n = count === null ? null : count.toLocaleString(lang);

  return (
    <>
      <Header lang={lang} />

      <main className="wrap" id="top">
        <section className="hero" aria-labelledby="hero-title">
          <h1 id="hero-title">
            <span>{t.h1[0]}</span>
            <span><em>{t.h1[1]}</em> {t.h1[2]}</span>
          </h1>
          <p className="lede">{t.lede}</p>

          <div className="command blueprint" role="group" aria-label={t.commandLabel}>
            <Corners />
            <div className="command-head">
              <span className="kicker">{t.paste}</span>
              <CopyButton text={COMMAND} t={t.copyButton} />
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
          <p className="note">{t.note} <a href={REPO}>{t.repo}</a></p>

          <div className="signup plate blueprint">
            <Corners />
            <WaitlistForm lang={lang} t={t.signup} />
            <div className="proof" aria-label="Live proof">
              <span className="kicker">
                <span className="dot" aria-hidden="true" />
                <span>{t.proof.kicker}</span>
              </span>
              <span className="count" aria-hidden="true">{n ?? "—"}</span>
              <p>
                <span className="sr-only">{n ?? t.proof.unknown} </span>
                {t.proof.people} <Sha />
              </p>
            </div>
          </div>
        </section>

        <section className="block" aria-labelledby="get-title">
          <h2 id="get-title">{t.getTitle}</h2>
          <div className="get plate blueprint">
            <Corners />
            {t.get.map((g) => (
              <article key={g.title}>
                <h3>{g.title}</h3>
                <p>{g.body}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="block" aria-labelledby="steps-title">
          <h2 id="steps-title">{t.stepsTitle}</h2>
          <p className="intro">{t.stepsIntro}</p>
          <ol className="steps">
            {t.steps.map((s, i) => (
              <li key={s.title}>
                <span className="num" aria-hidden="true">{i + 1}</span>
                <div className="step-body">
                  <div className="step-main">
                    <h3>{s.title}</h3>
                    <p>{s.what}</p>
                  </div>
                  <p className={s.you === t.nothing ? "you none" : "you"}>
                    <b>{t.you}</b>{s.you}
                  </p>
                </div>
              </li>
            ))}
          </ol>
        </section>

        <section className="block trust" aria-label={t.trustLabel}>
          <div className="plate blueprint">
            <Corners />
            <ul>
              {t.trust.map((line) => <li key={line}>{line}</li>)}
            </ul>
          </div>
        </section>
      </main>

      <Footer lang={lang} />
    </>
  );
}

// Brevo redirects here after the confirmation click (see redirectionUrl in actions.ts).
export function Confirmed({ lang }: { lang: Lang }) {
  const t = copy[lang].confirmed;
  return (
    <>
      <Header lang={lang} />
      <main className="wrap confirmed" id="top">
        <h1>{t.title}</h1>
        <p className="lede">{t.body}</p>
        <p className="note"><a href={copy[lang].path}>{t.back}</a></p>
      </main>
      <Footer lang={lang} />
    </>
  );
}
