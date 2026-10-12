import { Roadmap, roadmapMetadata } from "../../../roadmap-page";

export const generateMetadata = () => roadmapMetadata("pl");

export default function Page() {
  return <Roadmap lang="pl" />;
}
