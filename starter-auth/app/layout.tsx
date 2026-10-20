import type { Metadata } from "next";
import { readConfig } from "@/lib/config.ts";
import { copy } from "./copy";
import "./globals.css";

// Also rendered at build time (the 404 page), where SITE_URL may be unset.
export function generateMetadata(): Metadata {
  try {
    const c = readConfig();
    return { metadataBase: new URL(c.siteUrl), title: c.appName, description: copy.description };
  } catch {
    return { description: copy.description };
  }
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
