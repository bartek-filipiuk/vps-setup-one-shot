import { Html, metadataFor } from "../shell";

export const generateMetadata = () => metadataFor("en");

export default function Layout({ children }: { children: React.ReactNode }) {
  return <Html lang="en">{children}</Html>;
}
