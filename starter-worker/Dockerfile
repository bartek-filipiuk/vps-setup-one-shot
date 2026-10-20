# syntax=docker/dockerfile:1
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-alpine AS run
WORKDIR /app
ENV NODE_ENV=production PORT=3000
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json enqueue.js ./
COPY --chown=node:node src ./src
USER node
EXPOSE 3000
# Coolify uses this check when the Dockerfile has one (4.3.23 source); busybox wget exits 1 on a 503.
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 CMD ["wget", "-q", "-O", "/dev/null", "http://localhost:3000/api/health"]
CMD ["node", "src/main.js"]
