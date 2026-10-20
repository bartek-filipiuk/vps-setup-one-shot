import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Standalone output: the Docker image ships only server.js and traced deps.
  output: "standalone",
};

export default nextConfig;
