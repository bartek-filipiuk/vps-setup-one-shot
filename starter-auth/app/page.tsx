import { currentUser } from "@/lib/auth.ts";
import { copy, type SignInStatus } from "./copy";
import { Corners } from "./corners";
import { Footer, Header, Status } from "./shell";

// Per request: it reads the session cookie and the status from the address.
export const dynamic = "force-dynamic";

type Search = Promise<{ [key: string]: string | string[] | undefined }>;

function statusOf(q: { [key: string]: string | string[] | undefined }): SignInStatus | null {
  if (q.sent === "1") return "sent";
  const e = q.error;
  return e === "invalid" || e === "busy" || e === "expired" || e === "failed" ? e : null;
}

export default async function Page({ searchParams }: { searchParams: Search }) {
  const user = await currentUser();
  const status = statusOf(await searchParams);
  const t = copy.signIn;
  return (
    <>
      <Header user={user} />
      <main className="wrap confirmed">
        <h2>{t.title}</h2>
        {user ? (
          <p className="intro">
            {t.signedInAs} <b>{user.email}</b>. <a href="/account">{t.toAccount}</a>
          </p>
        ) : null}
        <div className="signup plate blueprint">
          <Corners />
          <form method="post" action="/api/auth/sign-in">
            <label htmlFor="email" className="title">{t.label}</label>
            <p className="what">{t.what}</p>
            <div className="row">
              <input
                id="email" name="email" type="email" inputMode="email" autoComplete="email" required maxLength={254}
                placeholder="you@example.com" className="input" aria-describedby="status"
                aria-invalid={status === "invalid"}
              />
              <input name="company" tabIndex={-1} autoComplete="off" aria-hidden="true" className="hp" />
              <button type="submit" className="btn-primary blueprint">
                <Corners />
                {t.button}
              </button>
            </div>
            {status ? <Status ok={status === "sent"} text={t.status[status]} /> : null}
          </form>
        </div>
      </main>
      <Footer />
    </>
  );
}
