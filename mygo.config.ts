import { defineConfig } from "mygo-cli";

export default defineConfig({
  name: "XClip",
  slug: "xclip",
  identifier: "com.yli.xclip",
  version: "0.2.1",
  icon: "resources/icon.png",
  main: "./cmd/app",
  devUrl: "http://localhost:5173",
  devCommand: "npm run dev:web",
  buildCommand: "npm run build:web",
  frontendDist: "web/dist",
  bindings: "web/src/mygo.ts",
  out: ".build/mygo",
  macos: { minimumSystemVersion: "14.0", signingIdentity: "-" },
});
