# Starter with sign-in: email link and transactional mail

The plumbing of vps-setup-one-shot's `starter/` (Next.js 16, Postgres 17, the same Dockerfile,
standalone output, schema at start, `/api/health`, non-root image listening on `::`) with
sign-in by a link sent by email, sessions in Postgres and mail over any SMTP provider. No
password, no OAuth, no auth library, no auth secret. Set up on a server with `AUTH.md` of
vps-setup-one-shot. English only: every visible string is in `app/copy.ts`.

## What runs

- `/`: the sign-in form. It posts the address to `/api/auth/sign-in`, which answers the same
  "a link is on its way" whether the address has an account or not (accounts are created at
  the first sign-in), and mails a link that works once, for 15 minutes.
- `/auth/callback?token=...`: where the link lands. Opening it uses nothing; the page shows the
  address and a **Continue** button that posts the token to `/api/auth/callback`. That second
  step is on purpose: mail scanners open links, and a one-step link would let another site sign
  your browser into its own account.
- `/account`: the example page behind sign-in, with sign-out and "sign out on every device".
- `/api/health`: `200 {"status":"ok","db":"ok"}` or `503 {"status":"error","db":"error"}`, the
  contract of every app of the setup. Mail is not part of it.
- At start (`instrumentation.ts`): the settings are checked (a missing one stops the container,
  the old version keeps running on Coolify) and the four tables are created.

## Settings (`.env.example`)

`DATABASE_URL`, `SITE_URL` (the public `https://` address: the base of the link, the origin
every form must come from, and what marks the cookie `Secure`), `MAIL_FROM` (an address or
domain the provider verified), `SMTP_URL` (`smtps://LOGIN:PASSWORD@HOST:465` or
`smtp://LOGIN:PASSWORD@HOST:587`, STARTTLS required; percent-encode `@ : / % #` in the
password), optional `APP_NAME`. `MAIL_LOG=1` sends nothing and prints each mail, link included,
to the log: for a local run and CI only, never on a server (anyone who reads the log can sign
in; the app says so at start).

## Security model

- Link tokens and session tokens are 32 random bytes; only their sha256 is stored, so a
  database dump or backup holds no working link or session.
- A link is single use (one atomic `update ... where used_at is null`) and expires in 15 minutes.
- Every form post must carry an `Origin` (or `Referer`) equal to `SITE_URL`'s origin; anything
  else gets 403. The session cookie is `HttpOnly`, `SameSite=Lax`, `Secure` on https, 30 days,
  and a new one is made at every sign-in. Sign-out deletes the row.
- Limits in Postgres, per 15 minutes: 20 sign-in requests per IP (the last `X-Forwarded-For`
  entry, the one Coolify's proxy adds), 5 mails per address (over it the answer stays "sent",
  without a mail, so nobody learns anything). This limits inbox flooding, it does not prevent
  it: `a+1@` and `a+2@` count as separate addresses; the per-IP limit still applies.
- Logged: "link requested", "signed in user <id>", the provider's message id. Never a token, a
  link or an address, except in `MAIL_LOG=1` mode.
- Turn the provider's click tracking off for these mails: it rewrites the link through the
  provider's servers.

## A page behind sign-in

```tsx
import { requireUser } from "@/lib/auth.ts";

export const dynamic = "force-dynamic";

export default async function Page() {
  const user = await requireUser(); // redirects to / without a session
  return <p>Hello {user.email}</p>;
}
```

Check on the server next to the data, in every page and route handler that needs it; there is
no `proxy.ts` (its checks can only be optimistic). A route handler that changes data checks the
origin too (`sameOrigin` in `lib/auth-core.ts`). Need OAuth, passkeys or roles: move to a
library then, keeping the `users` table (expand, then contract, as in `PREPARE-APP.md`).

## Local run

`npm ci`, a Postgres (`docker run -d --name auth-db -e POSTGRES_PASSWORD=dev -p 5432:5432
postgres:17-alpine`), `cp .env.example .env`, then `npm run dev` and open
`http://localhost:3000`; the sign-in link is in the terminal. `npm test` runs the unit tests
(fake database, no network). `bash test/fixtures.sh starter-auth` in vps-setup-one-shot builds
the image and signs in end to end against a real Postgres.
