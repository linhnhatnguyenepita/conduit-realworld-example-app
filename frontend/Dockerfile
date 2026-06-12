# syntax=docker/dockerfile:1

# ---- build: produce the static Vite bundle ----
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
COPY backend/package.json ./backend/package.json
COPY frontend/package.json ./frontend/package.json
# Only the frontend workspace (+ root) — avoids compiling backend native deps.
RUN npm ci --workspace=frontend
COPY frontend ./frontend
RUN npm run build --workspace=frontend

# ---- serve: nginx serving the SPA, proxying /api to the backend ----
FROM nginx:alpine AS runtime
COPY frontend/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/frontend/dist /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:80/ || exit 1
