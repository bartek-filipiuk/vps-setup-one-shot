// Runs once when the Next.js server starts (not during `next build`).
export async function register() {
  if (process.env.NEXT_RUNTIME !== "nodejs") return;
  const { configOrExit } = await import("./lib/config.ts");
  configOrExit();
  const { migrateOrExit } = await import("./lib/db.ts");
  await migrateOrExit();
}
