import { requireUser } from "@/lib/auth.ts";
import { copy } from "../copy";
import { Corners } from "../corners";
import { Footer, Header, Status } from "../shell";

// The example of a page behind sign-in: requireUser() first, then the data.
export const dynamic = "force-dynamic";

type Search = Promise<{ [key: string]: string | string[] | undefined }>;

export default async function Page({ searchParams }: { searchParams: Search }) {
  const user = await requireUser();
  const failed = (await searchParams).error === "failed";
  const t = copy.account;
  return (
    <>
      <Header user={user} />
      <main className="wrap confirmed">
        <h2>{t.title}</h2>
        <p className="intro">{t.signedInAs} <b>{user.email}</b></p>
        <p className="note">{t.note}</p>
        {failed ? <Status ok={false} text={t.failed} /> : null}
        <div className="row" style={{ marginTop: 24 }}>
          <form method="post" action="/api/auth/sign-out">
            <button type="submit" className="btn-primary blueprint"><Corners />{t.signOut}</button>
          </form>
          <form method="post" action="/api/auth/sign-out">
            <input type="hidden" name="everywhere" value="1" />
            <button type="submit" className="btn-primary blueprint"><Corners />{t.signOutEverywhere}</button>
          </form>
        </div>
      </main>
      <Footer />
    </>
  );
}
