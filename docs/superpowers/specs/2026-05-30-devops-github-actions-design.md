# DevOps Solution Design — Conduit (RealWorld) App

**Date:** 2026-05-30
**Status:** Approved for implementation
**Scope:** CI/CD, Monitoring, Security & Code Quality via GitHub Actions + Docker.
**Out of scope:** Live deployment (handled later via Ansible + Terraform on AWS).

## Goal

Add a complete DevOps layer to the existing npm-workspaces monorepo (Express + Sequelize/Postgres backend, React/Vite frontend) covering four pillars:

1. **Containerization** — reproducible, deployable Docker images.
2. **CI/CD** — automated lint, test, build, scan, and image publishing.
3. **Monitoring** — Prometheus metrics + Grafana dashboards.
4. **Security & Code Quality** — ESLint/Prettier, CodeQL, Dependabot, Trivy, SonarCloud.

Deployment itself is deferred: the CD pipeline's deliverable is **versioned, scanned Docker images in GHCR** that the future Ansible/Terraform AWS phase will pull.

## Decisions (locked)

| Topic | Decision |
|-------|----------|
| Image registry | **GHCR** (`ghcr.io/linhnhatnguyenepita/...`), authenticated with built-in `GITHUB_TOKEN` |
| Image structure | **Two separate images**: `conduit-backend` (Node) and `conduit-frontend` (nginx serving Vite build) |
| Monitoring | **Prometheus + Grafana** |
| Security/Quality | **ESLint + Prettier**, **CodeQL + Dependabot**, **Trivy**, **SonarCloud** |
| Deployment | Deferred to Ansible + Terraform (AWS) — not in this spec |

## Resolved Assumptions (verified against the code)

1. **No CI Postgres needed.** All three test files (`backend/helper/helpers.test.js`,
   `frontend/src/helpers/dateFormatter.test.js`, `errorHandler.test.js`) are pure unit tests;
   none touch Sequelize/DB. CI test job = `npm ci && npm run test`. No service container.
2. **ESLint baseline.** No ESLint config exists; Prettier is already in use (2-space, `// prettier-ignore`
   present). Implementation runs a one-time `prettier --write` + `eslint --fix` to establish a clean
   baseline, committed separately. CI lint gate fails on **errors only** (warnings allowed).
3. **Frontend uses relative `/api` URLs** — no build-time `VITE_API_URL`. The nginx prod image
   reverse-proxies `/api/` → backend, mirroring the existing `vite.config.js` dev proxy.

---

## 1. Containerization

### `backend/Dockerfile`
- Multi-stage, `node:20-alpine`.
- Stage 1: `npm ci` (workspace-aware; copy root + backend manifests).
- Stage 2: copy production node_modules + `backend/` source, run as non-root `node` user, `EXPOSE 3001`, `CMD ["node", "index.js"]`.
- Healthcheck hits `GET /api/health`.

### `frontend/Dockerfile`
- Stage 1 (`node:20-alpine`): `npm ci` + `npm run build -w frontend` → `frontend/dist`.
- Stage 2 (`nginx:alpine`): copy `dist` to `/usr/share/nginx/html` + custom `nginx.conf`.
- `nginx.conf`: serve SPA (`try_files ... /index.html`) and `location /api/ { proxy_pass http://backend:3001/api/; }`.

### `docker-compose.yml` (local full stack + monitoring)
Services: `postgres` (with healthcheck + volume), `backend` (depends_on postgres healthy, reads env), `frontend` (depends_on backend, port 8080→80), `prometheus`, `grafana`. A shared bridge network.

### Supporting files
- `backend/.dockerignore`, `frontend/.dockerignore` (node_modules, .env, dist, .git).
- `.env.example` documenting required vars (DB_*, JWT secret, NODE_ENV, PORT). Real `.env` stays gitignored.

---

## 2. CI/CD — GitHub Actions (`.github/workflows/`)

### `ci.yml` — on `pull_request` + `push` to `main`
Jobs (parallel where possible):
- **lint** — `npm ci`; `npm run lint` (ESLint) + `npm run format:check` (Prettier). Fails on ESLint errors.
- **test** — `npm ci`; `npm run test` with coverage (`vitest run --coverage`); upload `coverage/` as artifact.
- **build** — `docker build` both images (no push) to verify Dockerfiles.
- **trivy-fs** — Trivy filesystem/dependency scan (`fs` mode) on the repo; fails on HIGH/CRITICAL (configurable, `exit-code: 0` initially to avoid blocking on transitive CVEs — documented).
- **sonarcloud** — runs after `test`; uploads coverage to SonarCloud (`SonarSource/sonarcloud-github-action`). Needs `SONAR_TOKEN`.

### `codeql.yml` — CodeQL SAST
- Triggers: `pull_request`, `push` to `main`, weekly `schedule`.
- Language: `javascript-typescript`. Uses `github/codeql-action` (init → autobuild → analyze).

### `release.yml` — image publishing — on `push` to `main` + tags `v*`
- Logs into GHCR with `GITHUB_TOKEN` (`packages: write`).
- Builds **both** images via `docker/build-push-action`, tagged: `sha-<short>`, `latest` (on main), and semver (on tag) via `docker/metadata-action`.
- **Trivy image scan** on each built image before push; results uploaded to GitHub Security tab (SARIF). Push proceeds only if build+scan succeed.
- Images: `ghcr.io/linhnhatnguyenepita/conduit-backend`, `…/conduit-frontend`.

### `uptime.yml` — *optional*, scheduled (`cron`)
- Pings a configurable URL's `/api/health`; opens/comments an issue on failure. **Included but easy to delete** if no public URL exists yet. (Will be most useful after the AWS deploy phase.)

---

## 3. Monitoring — Prometheus + Grafana

### Backend instrumentation
- Add dependency **`prom-client`**.
- New `backend/middleware/metrics.js` (or `helper/metrics.js`): a Registry with `collectDefaultMetrics()` + an HTTP request duration histogram (labels: method, route, status) and request counter, applied as Express middleware.
- New routes in `index.js`:
  - `GET /metrics` — Prometheus exposition format (text/plain). Public, unauthenticated, **mounted before** `verifyToken`-guarded routers so scraping needs no JWT.
  - `GET /api/health` — `{ status: "ok", uptime, timestamp }`; also used by Docker healthchecks and `uptime.yml`.

### `monitoring/`
- `prometheus.yml` — scrape config: job `conduit-backend`, target `backend:3001`, `metrics_path: /metrics`, 15s interval.
- `grafana/provisioning/datasources/prometheus.yml` — auto-provision Prometheus datasource.
- `grafana/provisioning/dashboards/dashboard.yml` + `grafana/dashboards/conduit.json` — starter dashboard: HTTP request rate, p50/p95 latency, error rate (4xx/5xx), Node process CPU/memory/event-loop lag.
- Grafana exposed on `:3000` of the compose stack (admin/admin default, documented to change).

---

## 4. Security & Code Quality

### ESLint + Prettier
- Root `eslint.config.js` (ESLint 9 flat config) with per-workspace overrides:
  - frontend: `eslint-plugin-react`, `react-hooks`, `react-refresh`, browser globals, JSX.
  - backend: Node + CommonJS globals.
- `.prettierrc` matching existing style (2-space, double quotes — consistent with current code) + `.prettierignore`.
- Root `package.json` scripts: `lint` (`eslint .`), `lint:fix`, `format` (`prettier --write .`), `format:check`.
- Dev dependencies added at root: `eslint`, `prettier`, `eslint-plugin-react*`, `globals`, `@eslint/js`.

### Dependabot — `.github/dependabot.yml`
- Weekly updates for: npm (root, `/backend`, `/frontend`) + `github-actions`. Grouped minor/patch PRs.

### CodeQL — see `codeql.yml` above.

### Trivy — CI (`fs` deps scan) + release (image scan), SARIF → GitHub Security tab.

### SonarCloud
- `sonar-project.properties` (project/org keys, sources, `sonar.javascript.lcov.reportPaths=coverage/lcov.info`, test exclusions).
- CI job uploads analysis + coverage. **Vitest coverage** must emit `lcov` — add `@vitest/coverage-v8` and configure `coverage.reporter: ['text','lcov']` in `vitest.config.js`.

---

## Secrets / external setup required from the user

| Secret / setup | Used by | Notes |
|----------------|---------|-------|
| `SONAR_TOKEN` (repo secret) | SonarCloud job | Requires a SonarCloud account + org/project created |
| GHCR | release.yml | Uses built-in `GITHUB_TOKEN` — **no manual secret** |
| Grafana admin password | compose | Change from default `admin` |

AWS / ECR credentials are intentionally **not** part of this spec (Ansible/Terraform phase).

---

## File inventory (what gets created/modified)

```
.dockerignore (backend/, frontend/)
backend/Dockerfile
frontend/Dockerfile
frontend/nginx.conf
docker-compose.yml
.env.example
eslint.config.js
.prettierrc, .prettierignore
sonar-project.properties
backend/middleware/metrics.js          # + edits to backend/index.js (/metrics, /api/health, middleware)
monitoring/prometheus.yml
monitoring/grafana/provisioning/...     # datasource + dashboard provider
monitoring/grafana/dashboards/conduit.json
.github/workflows/ci.yml
.github/workflows/codeql.yml
.github/workflows/release.yml
.github/workflows/uptime.yml            # optional
.github/dependabot.yml
package.json                            # lint/format/test:coverage scripts + devDeps
vitest.config.js                        # coverage config
backend/package.json                    # + prom-client
README/docs                             # short "DevOps" section documenting the above
```

## Verification plan

- `npm run lint`, `npm run format:check`, `npm run test` pass locally after baseline autofix.
- `docker compose up` brings up backend, frontend (8080), Postgres, Prometheus (9090), Grafana (3000); `/api/health` and `/metrics` respond; Grafana dashboard shows data after generating traffic.
- `docker build` succeeds for both images.
- Workflows validated (actionlint / push to a branch) — CI green on a test PR.
