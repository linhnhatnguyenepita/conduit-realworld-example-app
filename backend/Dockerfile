# syntax=docker/dockerfile:1

# ---- deps: install backend production dependencies (workspace-aware) ----
FROM node:20-alpine AS deps
WORKDIR /app
# bcrypt is a native addon; musl/alpine needs build tools to compile it.
RUN apk add --no-cache python3 make g++
# Manifests only, so the layer is cached unless dependencies change.
COPY package.json package-lock.json ./
COPY backend/package.json ./backend/package.json
COPY frontend/package.json ./frontend/package.json
RUN npm ci --omit=dev --workspace=backend

# ---- runtime: minimal image, non-root ----
FROM node:20-alpine AS runtime
ENV NODE_ENV=production
ENV PORT=3001
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY backend ./backend
WORKDIR /app/backend
USER node
EXPOSE 3001
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD wget -qO- http://localhost:3001/api/health || exit 1
CMD ["node", "index.js"]
