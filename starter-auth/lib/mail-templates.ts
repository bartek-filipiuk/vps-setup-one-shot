// The mails the app sends, plain text first. Nothing a visitor typed goes into a mail (the
// address is only the recipient); everything interpolated is escaped anyway.
export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string);
}

export function signInMail({ appName, link, minutes }: { appName: string; link: string; minutes: number }) {
  const subject = `Sign in to ${appName}`;
  const text = [
    `Open this link to sign in to ${appName}:`,
    "",
    link,
    "",
    `It works once, for ${minutes} minutes. If you did not ask for it, ignore this mail; nobody can sign in without the link.`,
  ].join("\n");
  const a = escapeHtml(appName);
  const l = escapeHtml(link);
  const html = `<!doctype html>
<html><body style="font-family: system-ui, sans-serif; line-height: 1.5; color: #1d1f20">
<p>Open this link to sign in to ${a}:</p>
<p><a href="${l}" style="display: inline-block; padding: 10px 18px; background: #416180; color: #ffffff; text-decoration: none">Sign in to ${a}</a></p>
<p style="font-size: 13px; color: #555">Or copy this address into your browser:<br>${l}</p>
<p style="font-size: 13px; color: #555">It works once, for ${minutes} minutes. If you did not ask for it, ignore this mail; nobody can sign in without the link.</p>
</body></html>`;
  return { subject, text, html };
}
