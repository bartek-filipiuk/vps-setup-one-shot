import { readConfig } from "@/lib/config.ts";
import type { User } from "@/lib/auth-core.ts";
import { copy } from "./copy";

export function Header({ user }: { user: User | null }) {
  return (
    <header className="site-header">
      <nav className="nav" aria-label="Site">
        <a className="brand" href="/">{readConfig().appName}</a>
        {user ? <a className="navlink" href="/account">{copy.nav.account}</a> : <a className="navlink" href="/">{copy.nav.signIn}</a>}
      </nav>
    </header>
  );
}

export function Footer() {
  return (
    <footer className="site-footer">
      <div className="foot">
        <a className="live" href="/api/health">
          <span className="dot" aria-hidden="true" />
          <span>{copy.footer.health}</span>
        </a>
      </div>
    </footer>
  );
}

export function Status({ ok, text }: { ok: boolean; text: string }) {
  return (
    <p id="status" role="status" className={ok ? "status ok" : "status err"}>
      <span>{text}</span>
    </p>
  );
}
