# Lotti Brain. Build from the repository root:
#   docker build -f apps/brain/Dockerfile -t lotti-brain .
# syntax=docker/dockerfile:1

FROM node:24-slim AS build
WORKDIR /repo
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/brain/package.json apps/brain/package.json
RUN pnpm install --frozen-lockfile --filter @lotti/brain...
COPY tsconfig.base.json ./
COPY apps/brain/tsconfig.json apps/brain/tsconfig.build.json apps/brain/
COPY apps/brain/src apps/brain/src
RUN cd apps/brain && pnpm exec tsc -p tsconfig.build.json
RUN pnpm --filter @lotti/brain deploy --prod /out && cp -r apps/brain/dist /out/dist

FROM node:24-slim
# Tools the agent's `shell` tool can use.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl ripgrep jq git python3 \
 && rm -rf /var/lib/apt/lists/*

# ---- Subscription runtimes (Codex CLI, Claude Code CLI) -------------------------------------------------
# Used by the agent-runtime providers (src/integrations/runtimes/). Pinned to versions verified with Lotti;
# the build fails loudly when they cannot be installed.
RUN npm i -g @openai/codex@0.166.0 @anthropic-ai/claude-code@2.1.317
# ---------------------------------------------------------------------------------------------------------

ENV NODE_ENV=production DATA_DIR=/data PORT=8787
WORKDIR /app
COPY --from=build /out /app
# Run as the unprivileged `node` user (uid 1000); the shell tool inherits this. Only /data is writable:
# the app code stays root-owned so the agent cannot rewrite the server.
RUN mkdir -p /data && chown -R node:node /data
USER node
VOLUME /data
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD curl -fsS http://127.0.0.1:${PORT}/health || exit 1
CMD ["node", "dist/main.js"]
