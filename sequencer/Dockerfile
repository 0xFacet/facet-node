FROM node:20-alpine AS builder

WORKDIR /app

# Copy package files
COPY package*.json ./
RUN npm ci

# Copy source code
COPY tsconfig.json ./
COPY src ./src

# Build
RUN npm run build

# Production image
FROM node:20-alpine

WORKDIR /app

# Install production dependencies only
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Copy built application
COPY --from=builder /app/dist ./dist

# Create data directory
RUN mkdir -p /data

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8547/health || exit 1

# Expose ports
EXPOSE 8547 9090

# Volume for database
VOLUME ["/data"]

# Run as non-root user
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001
USER nodejs

# Start the application
CMD ["node", "dist/index.js"]