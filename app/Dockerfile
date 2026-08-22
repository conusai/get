# Release host for ConusAI Cloud.
#
# Single stage on purpose: there are no dependencies to install and nothing to
# compile, so a builder stage would only add a layer that can go wrong. The
# image is the Bun runtime plus three TypeScript files.
#
# Build context is this directory (app/). Configure Dokploy with:
#   Build path / context : app
#   Dockerfile           : app/Dockerfile
#   Volume mount         : <volume> -> /data
#   Env                  : CONUSAI_PUBLISH_TOKEN, PUBLIC_URL, MODE
FROM oven/bun:1.3-alpine

# su-exec lets the entrypoint fix ownership of the mounted volume as root and
# then drop privileges before running the server. A Docker/Dokploy volume is
# created root-owned, so a container that starts unprivileged cannot write to
# its own storage on first boot.
RUN apk add --no-cache su-exec curl

WORKDIR /app

COPY package.json ./
COPY server.ts storage.ts views.ts ./
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV PORT=3000 \
    MODE=origin \
    CONUSAI_DATA_DIR=/data

EXPOSE 3000
VOLUME ["/data"]

# The server refuses to start without a publish token in origin mode, so an
# unhealthy container here means a misconfiguration, not a crash loop to ignore.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/healthz" || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["bun", "run", "/app/server.ts"]
