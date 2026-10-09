// Runs once when the Next.js server starts (not during `next build`).
export async function register() {
  if (process.env.NEXT_RUNTIME !== "nodejs") return;
  const { migrateOrExit } = await import("./lib/db");
  await migrateOrExit();
}
