import { Roadmap, roadmapMetadata } from "../../roadmap-page";

export const generateMetadata = () => roadmapMetadata("en");

export default function Page() {
  return <Roadmap lang="en" />;
}
