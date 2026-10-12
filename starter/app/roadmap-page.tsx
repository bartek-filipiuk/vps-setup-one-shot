import type { Metadata } from "next";
import { copy, type Lang } from "./copy";
import { Corners } from "./corners";
import { Footer, Header } from "./landing";
import { roadmap, type LaneKey } from "./roadmap";

const LANES: LaneKey[] = ["now", "next", "later", "ideas"];

export function roadmapMetadata(lang: Lang): Metadata {
  const t = copy[lang].roadmap;
  const other = copy[lang].other.lang as Lang;
  return {
    title: t.title,
    description: t.description,
    alternates: {
      canonical: t.path,
      languages: { [lang]: t.path, [other]: copy[other].roadmap.path, "x-default": copy.en.roadmap.path },
    },
  };
}

export function Roadmap({ lang }: { lang: Lang }) {
  const t = copy[lang].roadmap;
  const data = roadmap[lang];
  const other = copy[lang].other.lang as Lang;
  return (
    <>
      <Header lang={lang} otherPath={copy[other].roadmap.path} current="roadmap" />

      <main className="wrap roadmap" id="top">
        <section className="hero" aria-labelledby="roadmap-title">
          <h1 id="roadmap-title">
            <span>{t.h1[0]}</span>
            <span><em>{t.h1[1]}</em> {t.h1[2]}</span>
          </h1>
          <p className="lede">{t.lead}</p>

          <div className="plate blueprint framing">
            <Corners />
            <section aria-labelledby="for-title">
              <h2 id="for-title" className="kicker">{t.forLabel}</h2>
              <p>{t.forWhom}</p>
            </section>
            <section aria-labelledby="rules-title">
              <h2 id="rules-title" className="kicker">{t.rulesLabel}</h2>
              <ol>
                {t.rules.map((r) => <li key={r}>{r}</li>)}
              </ol>
            </section>
          </div>
        </section>

        <section className="block" aria-label={t.nav}>
          <div className="lanes">
            {LANES.map((key) => (
              <section key={key} className={`lane lane-${key}`} aria-labelledby={`lane-${key}`}>
                <h2 id={`lane-${key}`}>
                  {t.lanes[key].name}
                  <span className="lane-note">{t.lanes[key].note}</span>
                </h2>
                <ol>
                  {data.lanes[key].map((it) => (
                    <li key={it.id}>
                      <span className="rid" aria-hidden="true">{it.id}</span>
                      <h3><span className="sr-only">{it.id} </span>{it.name}</h3>
                      <p>{it.value}</p>
                      {it.done && <p className="done"><b>{t.doneWhen}</b> {it.done}</p>}
                    </li>
                  ))}
                </ol>
              </section>
            ))}
          </div>
        </section>

        <section className="block" aria-labelledby="shipped-title">
          <h2 id="shipped-title">{t.shippedTitle}</h2>
          <dl className="shipped plate blueprint">
            <Corners />
            {data.shipped.map((s) => (
              <div key={s.date + s.text}>
                <dt>{s.date}</dt>
                <dd>{s.text}</dd>
              </div>
            ))}
          </dl>
          <p className="note">{t.source} <a href="https://github.com/bartek-filipiuk/vps-setup-one-shot/blob/main/ROADMAP.md">ROADMAP.md</a></p>
        </section>
      </main>

      <Footer lang={lang} />
    </>
  );
}
