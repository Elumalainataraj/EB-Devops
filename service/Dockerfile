# syntax=docker/dockerfile:1

# ---- Build stage -----------------------------------------------------------
# Pinned digest-style tag (not `latest`). No native deps here, but this stage
# is where `npm ci` / compilation would happen for a real app.
FROM node:20.11.1-alpine3.19 AS build

WORKDIR /app

COPY package.json ./
# No lockfile / deps in this minimal service, but this is the correct
# pattern once one exists: `npm ci --omit=dev` for reproducible installs.
RUN npm install --omit=dev

COPY server.js ./

# ---- Runtime stage ----------------------------------------------------------
FROM node:20.11.1-alpine3.19 AS runtime

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

# Only bring across what's needed to run — keeps the image lean and avoids
# shipping build-time tooling.
COPY --from=build /app/package.json ./
COPY --from=build /app/server.js ./
COPY --from=build /app/node_modules ./node_modules

# The official node:alpine image ships a non-root `node` user (uid 1000,
# gid 1000) already — reuse it instead of creating a new one.
USER node

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:'+(process.env.PORT||3000)+'/healthz',res=>process.exit(res.statusCode===200?0:1)).on('error',()=>process.exit(1))"

CMD ["node", "server.js"]
