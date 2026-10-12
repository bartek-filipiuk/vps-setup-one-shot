import type { Metadata } from "next";
import { Barlow, Barlow_Condensed, IBM_Plex_Mono } from "next/font/google";
import { copy, type Lang } from "./copy";
import "./globals.css";

// Fonts are downloaded at build time and served from this app; no third-party requests at runtime.
// latin-ext carries the Polish letters (ą, ę, ł, ż); without it headings fall back to a system font.
const heading = Barlow_Condensed({ subsets: ["latin", "latin-ext"], weight: ["600"], variable: "--font-heading" });
const body = Barlow({ subsets: ["latin", "latin-ext"], weight: ["400", "500", "600"], variable: "--font-body" });
const mono = IBM_Plex_Mono({ subsets: ["latin", "latin-ext"], weight: ["400"], variable: "--font-mono" });

export function metadataFor(lang: Lang): Metadata {
  const t = copy[lang];
  return {
    // Absolute hreflang URLs need the public origin; without SITE_URL Next falls back to localhost.
    metadataBase: process.env.SITE_URL ? new URL(process.env.SITE_URL) : undefined,
    title: t.title,
    description: t.description,
    alternates: {
      canonical: t.path,
      languages: { [lang]: t.path, [t.other.lang]: t.other.path, "x-default": copy.en.path },
    },
  };
}

// Each language is its own root layout (route groups), so <html lang> is right without a proxy.
export function Html({ lang, children }: { lang: Lang; children: React.ReactNode }) {
  return (
    <html lang={lang} className={`${heading.variable} ${body.variable} ${mono.variable}`}>
      <body>{children}</body>
    </html>
  );
}
