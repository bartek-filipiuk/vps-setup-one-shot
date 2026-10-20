// Every visible string. Translate here; the code only reads these.
export type SignInStatus = "sent" | "invalid" | "busy" | "expired" | "failed";

export const copy = {
  description: "Sign in with a link sent to your email address.",
  nav: { account: "Your account", signIn: "Sign in" },
  signIn: {
    title: "Sign in",
    what: "Enter your email address. We send you a link that signs you in; no password.",
    label: "Email address",
    button: "Send me a link",
    signedInAs: "You are signed in as",
    toAccount: "Go to your account",
    status: {
      sent: "If that address is valid, a link is on its way. It works for 15 minutes.",
      invalid: "That doesn't look like an email address. Check for a typo.",
      busy: "Too many tries from your network. Wait fifteen minutes and try again.",
      expired: "That link was already used or has expired. Ask for a new one below.",
      failed: "The server couldn't send the mail right now. Nothing was sent; try again in a minute.",
    } satisfies Record<SignInStatus, string>,
  },
  confirm: {
    title: "Confirm sign-in",
    as: "Sign in as",
    button: "Continue",
    why: "One more click, so a link opened by a mail scanner signs nobody in.",
    invalid: "This link was already used or has expired.",
    failed: "The server couldn't check this link right now. Try again in a minute.",
    again: "Ask for a new link",
  },
  account: {
    title: "Your account",
    signedInAs: "Signed in as",
    note: "This page is the example of a page behind sign-in: it calls requireUser() first.",
    signOut: "Sign out",
    signOutEverywhere: "Sign out on every device",
    failed: "Signing out didn't work on the server. Try again in a minute.",
  },
  footer: { health: "Health check: /api/health" },
};
