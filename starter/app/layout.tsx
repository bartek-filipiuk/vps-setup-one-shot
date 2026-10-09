import type { Metadata } from "next";
import { IBM_Plex_Mono, IBM_Plex_Sans, Newsreader } from "next/font/google";
import "./globals.css";

// Fonts are downloaded at build time and served from this app; no third-party requests at runtime.
const display = Newsreader({ subsets: ["latin"], style: ["normal", "italic"], axes: ["opsz"], variable: "--font-display" });
const body = IBM_Plex_Sans({ subsets: ["latin", "latin-ext"], weight: ["400", "600"], variable: "--font-body" });
const mono = IBM_Plex_Mono({ subsets: ["latin"], weight: ["400"], variable: "--font-mono" });

export const metadata: Metadata = {
  title: "One prompt. Your own deploy server.",
  description:
    "A guided setup your AI coding agent runs for you: Hetzner VPS, Coolify, HTTPS, Postgres and push-to-deploy from GitHub. Free boilerplate for the waitlist.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${display.variable} ${body.variable} ${mono.variable}`}>
      <body>{children}</body>
    </html>
  );
}
