"use client";

import { useActionState } from "react";
import { joinWaitlist } from "./actions";
import { Corners } from "./corners";

const Check = () => (
  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M20 6 9 17l-5-5" /></svg>
);
const Alert = () => (
  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10" /><line x1="12" x2="12" y1="8" y2="12" /><line x1="12" x2="12.01" y1="16" y2="16" /></svg>
);

export function WaitlistForm() {
  const [state, action, pending] = useActionState(joinWaitlist, null);
  const failed = state?.ok === false;

  return (
    <form action={action}>
      <label htmlFor="email">Get the boilerplate. Free, when it ships.</label>
      <div className="row">
        <input
          id="email" name="email" type="email" inputMode="email" autoComplete="email" required maxLength={254}
          placeholder="you@example.com" className="input" readOnly={pending} aria-invalid={failed} aria-describedby="signup-status"
        />
        <input name="company" tabIndex={-1} autoComplete="off" aria-hidden="true" className="hp" />
        <button type="submit" className="btn-primary blueprint" disabled={pending} aria-busy={pending}>
          <Corners />
          {pending ? "Sending…" : "Send me the repo"}
        </button>
      </div>
      <p id="signup-status" role="status" aria-live="polite" className={state?.ok ? "status ok" : failed ? "status err" : "status"}>
        {pending ? (
          "Saving your address…"
        ) : state ? (
          <>
            {state.ok ? <Check /> : <Alert />}
            <span>{state.message}</span>
          </>
        ) : (
          "One mail when the repo ships, then only when the guide gets fixed."
        )}
      </p>
    </form>
  );
}
