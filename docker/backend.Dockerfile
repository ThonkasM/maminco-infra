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
#   --build-arg NODE_DIGEST=sha256:<digest>
# =============================================================================
ARG NODE_VERSION=22.22-alpine3.23
ARG NODE_DIGEST=

FROM node:${NODE_VERSION}${NODE_DIGEST:+@${NODE_DIGEST}} AS base
WORKDIR /app
RUN apk add --no-cache openssl tini

FROM base AS deps
COPY package.json package-lock.json ./
RUN npm ci

FROM deps AS build
COPY . .
RUN npx prisma generate && npm run build

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
