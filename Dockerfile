# syntax=docker/dockerfile:1@sha256:572cebbc2b15e6f84c077742952674889cb63cd5e9b80abdffcbe587b6f19183

# Base images come from chainringlabs/base-images: signature-verified copies of
# cgr.dev/chainguard/node, held back 3 days (`aged`). Both tags move together
# from the same daily record, so builder and runtime stay on one Node major.

# ---- Build stage: Chainguard node "dev" variant (npm + shell), paired to the
# runtime image so the Node major matches (avoids native-ABI skew). ----
FROM ghcr.io/chainringlabs/base/node-dev:aged@sha256:7a3fc49ffe9c0b0968674869a7bf6b9ad1d3cc490985399e1b999601fc896d44 AS build
USER root
WORKDIR /app

# Install with the lockfile first for better layer caching.
COPY package.json package-lock.json .npmrc ./
COPY server/package.json server/
COPY client/package.json client/
RUN npm ci

# Build both workspaces, then drop dev dependencies from node_modules.
COPY . .
RUN npm run build && npm prune --omit=dev

# Pre-create an empty data dir so the runtime can own it without a shell.
RUN mkdir -p /data-empty

# ---- Runtime stage: hardened, distroless, non-root (uid 65532) ----
FROM ghcr.io/chainringlabs/base/node:aged@sha256:0e44a5a00b241314d60761ccb9e13d7af715947dd976400101089d099f3b50e1 AS runtime
ENV NODE_ENV=production \
    DATA_DIR=/data \
    PORT=8080 \
    HOST=0.0.0.0
WORKDIR /app

# Copy only what the server needs at runtime, owned by the non-root user.
COPY --from=build --chown=65532:65532 /app/node_modules ./node_modules
COPY --from=build --chown=65532:65532 /app/server/package.json ./server/package.json
COPY --from=build --chown=65532:65532 /app/server/dist ./server/dist
COPY --from=build --chown=65532:65532 /app/client/dist ./client/dist
COPY --from=build --chown=65532:65532 /app/package.json ./package.json
COPY --from=build --chown=65532:65532 /data-empty /data

VOLUME ["/data"]
USER 65532
EXPOSE 8080

# Exec-form healthcheck driven by node's fetch (no package manager / curl here).
HEALTHCHECK --interval=30s --timeout=4s --start-period=5s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

# The base image's ENTRYPOINT is /usr/bin/node; pass the server entry as its arg.
CMD ["server/dist/index.js"]
