"use client";

import { useActionState } from "react";
import { joinWaitlist } from "./actions";
import type { Copy, Lang } from "./copy";
import { Corners } from "./corners";

const Check = () => (
  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M20 6 9 17l-5-5" /></svg>
);
const Alert = () => (
  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10" /><line x1="12" x2="12" y1="8" y2="12" /><line x1="12" x2="12.01" y1="16" y2="16" /></svg>
);

export function WaitlistForm({ lang, t }: { lang: Lang; t: Copy["signup"] }) {
  const [state, action, pending] = useActionState(joinWaitlist, null);
  const failed = state?.ok === false;

  return (
    <form action={action}>
      <label htmlFor="email" className="title">{t.title}</label>
      <p className="what">{t.what}</p>
      <input type="hidden" name="lang" value={lang} />
      <div className="row">
        <input
          id="email" name="email" type="email" inputMode="email" autoComplete="email" required maxLength={254}
          placeholder="you@example.com" className="input" readOnly={pending}
          aria-invalid={state?.status === "invalid"} aria-describedby="signup-status"
        />
        <input name="company" tabIndex={-1} autoComplete="off" aria-hidden="true" className="hp" />
        <button type="submit" className="btn-primary blueprint" disabled={pending} aria-busy={pending}>
          <Corners />
          {pending ? t.sending : t.button}
        </button>
      </div>
      <label className="consent">
        <input type="checkbox" name="consent" required aria-invalid={state?.status === "consent"} />
        <span>
          {t.consent} <a href={t.privacyUrl}>{t.privacy}</a>
        </span>
      </label>
      <p id="signup-status" role="status" aria-live="polite" className={state?.ok ? "status ok" : failed ? "status err" : "status"}>
        {pending ? (
          t.saving
        ) : state ? (
          <>
            {state.ok ? <Check /> : <Alert />}
            <span>{t.status[state.status]}</span>
          </>
        ) : null}
      </p>
    </form>
  );
}
