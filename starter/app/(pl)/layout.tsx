import { Html, metadataFor } from "../shell";

export const generateMetadata = () => metadataFor("pl");

export default function Layout({ children }: { children: React.ReactNode }) {
  return <Html lang="pl">{children}</Html>;
}
