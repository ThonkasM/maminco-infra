# syntax=docker/dockerfile:1
# =============================================================================
# maminco-frontend — Next.js 16 (App Router), `output: 'standalone'`
# Build context: ../maminco-frontend (the app repo)
#   docker build -f docker/frontend.Dockerfile ../maminco-frontend
#
# Requires `output: 'standalone'` in next.config.ts (the app owns that).
# NEXT_PUBLIC_* values are inlined into the browser bundle at BUILD time and
# must be origins only (no trailing slash, no /api).
#
# Base image pinning: the tag is fixed. To pin by digest as well, pass
#   --build-arg NODE_DIGEST=sha256:<digest>
# =============================================================================
ARG NODE_VERSION=22.22-alpine3.23
ARG NODE_DIGEST=

FROM node:${NODE_VERSION}${NODE_DIGEST:+@${NODE_DIGEST}} AS base
WORKDIR /app
RUN apk add --no-cache libc6-compat tini

FROM base AS deps
COPY package.json package-lock.json ./
RUN npm ci

FROM deps AS build
ARG NEXT_PUBLIC_API_URL=http://localhost
ARG NEXT_PUBLIC_SOCKET_URL=http://localhost
ARG NEXT_PUBLIC_SITE_URL=http://localhost
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL \
    NEXT_PUBLIC_SOCKET_URL=$NEXT_PUBLIC_SOCKET_URL \
    NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL \
    NEXT_TELEMETRY_DISABLED=1
COPY . .
RUN npm run build

FROM base AS runtime
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3001 \
    HOSTNAME=0.0.0.0
COPY --from=build --chown=node:node /app/public ./public
COPY --from=build --chown=node:node /app/.next/standalone ./
COPY --from=build --chown=node:node /app/.next/static ./.next/static
USER node
EXPOSE 3001
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
    CMD node -e "require('http').get({host:'127.0.0.1',port:process.env.PORT||3001,path:'/',timeout:4000},r=>process.exit(r.statusCode<500?0:1)).on('error',()=>process.exit(1))"
ENTRYPOINT ["/sbin/tini", "-s", "--"]
CMD ["node", "server.js"]
