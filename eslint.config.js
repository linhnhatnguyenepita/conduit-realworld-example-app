import js from "@eslint/js";
import globals from "globals";
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";
import reactRefresh from "eslint-plugin-react-refresh";

export default [
  {
    ignores: [
      "**/node_modules/**",
      "**/dist/**",
      "**/build/**",
      "**/coverage/**",
      "backend/migrations/**",
      "backend/seeders/**",
    ],
  },
  js.configs.recommended,

  // Backend — Node.js / CommonJS
  {
    files: ["backend/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "commonjs",
      globals: { ...globals.node },
    },
    rules: {
      "no-unused-vars": ["warn", { argsIgnorePattern: "^_|^next$" }],
    },
  },

  // Frontend — React / ESM / browser
  {
    files: ["frontend/**/*.{js,jsx}"],
    plugins: {
      react,
      "react-hooks": reactHooks,
      "react-refresh": reactRefresh,
    },
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: { ...globals.browser },
      parserOptions: { ecmaFeatures: { jsx: true } },
    },
    settings: { react: { version: "detect" } },
    rules: {
      ...react.configs.flat.recommended.rules,
      ...reactHooks.configs.recommended.rules,
      "react/react-in-jsx-scope": "off",
      "react/prop-types": "off",
      "react-refresh/only-export-components": [
        "warn",
        { allowConstantExport: true },
      ],
      "no-unused-vars": "warn",
    },
  },

  // Test files (Vitest globals enabled in config)
  {
    files: ["**/*.test.{js,jsx}", "**/setupTests.js"],
    languageOptions: {
      globals: { ...globals.node, ...globals.browser, ...globals.vitest },
    },
  },

  // Config files at repo root run under Node
  {
    files: ["*.config.js", "vitest.config.js"],
    languageOptions: {
      sourceType: "module",
      globals: { ...globals.node },
    },
  },
];
