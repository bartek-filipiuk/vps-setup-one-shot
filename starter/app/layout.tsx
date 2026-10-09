import type { Metadata } from "next";
import { Barlow, Barlow_Condensed, IBM_Plex_Mono } from "next/font/google";
import "./globals.css";

// Fonts are downloaded at build time and served from this app; no third-party requests at runtime.
const heading = Barlow_Condensed({ subsets: ["latin"], weight: ["600"], variable: "--font-heading" });
const body = Barlow({ subsets: ["latin", "latin-ext"], weight: ["400", "500", "600"], variable: "--font-body" });
const mono = IBM_Plex_Mono({ subsets: ["latin"], weight: ["400"], variable: "--font-mono" });

export const metadata: Metadata = {
  title: "vps-setup-one-shot — One command. Your own deploy server.",
  description:
    "Paste one line into your terminal. Your AI coding agent sets up a Hetzner VPS with Coolify, HTTPS, Postgres and push-to-deploy from GitHub. Free boilerplate for the waitlist.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${heading.variable} ${body.variable} ${mono.variable}`}>
      <body>{children}</body>
    </html>
  );
}
