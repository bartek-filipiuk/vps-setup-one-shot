import type { Metadata } from "next";
import { pool } from "@/lib/db.ts";
import { currentUser } from "@/lib/auth.ts";
import { hashToken, peekLoginToken, validRawToken } from "@/lib/auth-core.ts";
import { copy } from "../../copy";
import { Corners } from "../../corners";
import { Footer, Header, Status } from "../../shell";

// The link from the mail lands here. Opening it uses nothing (mail scanners open links too);
// the button posts the token, and only that signs in. The token is in this page's address, so
// the page sends no referrer to other sites.
export const dynamic = "force-dynamic";
export const metadata: Metadata = { referrer: "same-origin", robots: { index: false } };

type Search = Promise<{ [key: string]: string | string[] | undefined }>;

async function lookup(token: unknown): Promise<{ email: string | null; failed: boolean }> {
  if (!validRawToken(token)) return { email: null, failed: false };
  try {
    return { email: await peekLoginToken(pool, hashToken(token)), failed: false };
  } catch (err) {
    console.error(`auth: link check failed: ${(err as Error).message}`);
    return { email: null, failed: true };
  }
}

export default async function Page({ searchParams }: { searchParams: Search }) {
  const token = (await searchParams).token;
  const [user, link] = await Promise.all([currentUser(), lookup(token)]);
  const t = copy.confirm;
  return (
    <>
      <Header user={user} />
      <main className="wrap confirmed">
        <h2>{t.title}</h2>
        {link.email ? (
          <div className="signup plate blueprint">
            <Corners />
            <form method="post" action="/api/auth/callback">
              <p className="what">{t.as} <b>{link.email}</b></p>
              <input type="hidden" name="token" value={String(token)} />
              <div className="row">
                <button type="submit" className="btn-primary blueprint">
                  <Corners />
                  {t.button}
                </button>
              </div>
              <p className="note">{t.why}</p>
            </form>
          </div>
        ) : (
          <>
            <Status ok={false} text={link.failed ? t.failed : t.invalid} />
            <p className="intro"><a href="/">{t.again}</a></p>
          </>
        )}
      </main>
      <Footer />
    </>
  );
}
