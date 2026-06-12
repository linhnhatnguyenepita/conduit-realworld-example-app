import react from "@vitejs/plugin-react-swc";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  test: {
    globals: true,
    environment: "jsdom",
    setupFiles: "frontend/src/setupTests.js",
    css: true,
    coverage: {
      provider: "v8",
      reporter: ["text", "lcov"],
      reportsDirectory: "coverage",
      include: ["backend/**/*.js", "frontend/src/**/*.{js,jsx}"],
      exclude: [
        "**/*.test.{js,jsx}",
        "**/node_modules/**",
        "backend/migrations/**",
        "backend/seeders/**",
        "frontend/src/setupTests.js",
      ],
    },
  },
});
