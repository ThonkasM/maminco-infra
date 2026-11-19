# syntax=docker/dockerfile:1
# =============================================================================
# maminco-backend — NestJS + Prisma + socket.io
# Build context: ../maminco-backend (the app repo)
#   docker build -f docker/backend.Dockerfile --target runtime ../maminco-backend
#   docker build -f docker/backend.Dockerfile --target migrate ../maminco-backend
#
# Targets:
#   runtime  production server (prod dependencies only, non-root, tini)
#   migrate  one-shot job: prisma migrate deploy, seed only when SEED=true
#
# Base image pinning: the tag is fixed. To pin by digest as well, resolve it
# with `docker buildx imagetools inspect node:<tag>` and pass
#   --build-arg NODE_IMAGE=node:<tag>@sha256:<digest>
# =============================================================================
ARG NODE_IMAGE=node:22.22-alpine3.23

FROM ${NODE_IMAGE} AS base
WORKDIR /app
RUN apk upgrade --no-cache && apk add --no-cache openssl tini

FROM base AS deps
COPY package.json package-lock.json ./
RUN npm ci

FROM deps AS build
COPY . .
RUN DATABASE_URL="postgresql://build:build@localhost:5432/build" npx prisma generate && npm run build

FROM base AS prod-deps
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

FROM build AS migrate
ENV NODE_ENV=production \
    SEED=false
USER node
ENTRYPOINT ["/sbin/tini", "-s", "--"]
CMD ["sh", "-c", "node_modules/.bin/prisma migrate deploy && if [ \"$SEED\" = \"true\" ]; then node_modules/.bin/prisma db seed; fi"]

FROM base AS runtime
# The npm CLI bundled in the base image is not needed at runtime and carries its own advisories.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack
ENV NODE_ENV=production \
    PORT=3000
COPY --from=prod-deps --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node package.json ./
USER node
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=5s --start-period=40s --retries=5 \
    CMD node -e "require('http').get({host:'127.0.0.1',port:process.env.PORT||3000,path:'/',timeout:4000},r=>process.exit(r.statusCode<500?0:1)).on('error',()=>process.exit(1))"
ENTRYPOINT ["/sbin/tini", "-s", "--"]
CMD ["node", "dist/main.js"]
