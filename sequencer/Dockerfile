FROM node:20-alpine AS builder

WORKDIR /app

# Tooling required to build native modules (better-sqlite3, c-kzg)
RUN apk add --no-cache python3 make g++

# Install dependencies
COPY package.json package-lock.json ./
RUN npm ci

# Copy source and build
COPY tsconfig.json ./
COPY eslint.config.mjs ./
COPY src ./src
RUN npm run typecheck && npm run build

# Strip dev dependencies so we can reuse node_modules in the runtime image
RUN npm prune --omit=dev

FROM node:20-alpine

WORKDIR /app

ENV NODE_ENV=production

# Runtime deps for native modules & health checks
RUN apk add --no-cache libstdc++ curl && \
    mkdir -p /data

COPY package.json package-lock.json ./
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist

RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001 && \
    chown -R nodejs:nodejs /app /data

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl --fail --silent http://localhost:${PORT:-8545}/health || exit 1

EXPOSE 8545 9090
VOLUME ["/data"]

USER nodejs

CMD ["node", "dist/index.js"]
