import { Landing } from "../landing";

// Rendered per request: the count comes from Postgres, not from build time.
export const dynamic = "force-dynamic";

export default function Page() {
  return <Landing lang="en" />;
}
