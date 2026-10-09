"use client";

import { useActionState } from "react";
import { joinWaitlist } from "./actions";

export function WaitlistForm() {
  const [state, action, pending] = useActionState(joinWaitlist, null);

  return (
    <form action={action} className="form">
      <label htmlFor="email" className="sr-only">Email address</label>
      <input id="email" name="email" type="email" required maxLength={254} autoComplete="email" placeholder="you@yourdomain.dev" />
      <input name="company" tabIndex={-1} autoComplete="off" aria-hidden="true" className="hp" />
      <button type="submit" disabled={pending}>{pending ? "Saving…" : "Send me the repo"}</button>
      <p role="status" className={state?.ok === false ? "msg error" : "msg"}>{state?.message}</p>
    </form>
  );
}
