FROM node:20-alpine AS builder

# Install build dependencies for native modules
RUN apk add --no-cache python3 make g++ py3-pip

WORKDIR /app

# Copy package files
COPY package.json package-lock.json ./
RUN npm ci

# Copy source code and config files
COPY tsconfig.json ./
COPY .eslintrc.json ./
COPY src ./src

# Build (skip linting in Docker, just compile)
RUN npm run typecheck && npx tsc

# Production image
FROM node:20-alpine

# Set production environment
ENV NODE_ENV=production

# Install runtime dependencies for native modules (needed for c-kzg and better-sqlite3)
RUN apk add --no-cache python3 make g++ py3-pip

WORKDIR /app

# Install production dependencies only
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Copy built application
COPY --from=builder /app/dist ./dist

# Create data directory and set permissions for non-root user
RUN mkdir -p /data && \
    addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001 && \
    chown -R nodejs:nodejs /app /data

# Health check - use PORT env var (defaults to 8545)
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:${PORT:-8545}/health || exit 1

# Expose ports - main RPC and metrics
EXPOSE 8545 9090

# Volume for database
VOLUME ["/data"]

# Switch to non-root user (already created above)
USER nodejs

# Start the application
CMD ["node", "dist/index.js"]