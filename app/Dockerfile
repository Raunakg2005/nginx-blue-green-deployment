# ==========================================
# Stage 1: Dependency Builder
# ==========================================
FROM node:20-alpine AS builder

WORKDIR /app

# Copy package manifests
COPY package*.json ./

# Install production dependencies only
RUN npm install --omit=dev

# ==========================================
# Stage 2: Hardened Minimal Production Image
# ==========================================
FROM node:20-alpine

# Install dumb-init for proper UNIX PID 1 process management & signal forwarding, plus curl for container health checks
RUN apk --no-cache add dumb-init curl

WORKDIR /app

# Copy dependencies from builder
COPY --from=builder /app/node_modules ./node_modules

# Copy application code
COPY package.json server.js ./

# Set secure ownership and drop privileges to non-root user
RUN chown -R node:node /app
USER node

# Expose default port
EXPOSE 8080

# Configure health check within container
HEALTHCHECK --interval=5s --timeout=3s --retries=3 --start-period=3s \
  CMD curl -f http://localhost:${PORT:-8080}/health || exit 1

# dumb-init forwards SIGTERM to Node for graceful connection draining
ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["node", "server.js"]
