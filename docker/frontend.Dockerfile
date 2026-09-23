# syntax=docker/dockerfile:1
# =============================================================================
# maminco-frontend — Next.js 16 (App Router)
# Build context: ../maminco-frontend   (the app repo; keeps it untouched)
#   docker build -f docker/frontend.Dockerfile ../maminco-frontend
#
# NOTE: the app uses middleware.ts, so it must be served by a Node process
# (`next start`). It is NOT exported statically and cannot live on S3 alone.
# NEXT_PUBLIC_* variables are compiled into the client bundle at build time.
# =============================================================================

# --- deps / build stage ------------------------------------------------------
FROM node:22-alpine AS builder
WORKDIR /app

RUN apk add --no-cache libc6-compat

# Build-time public configuration (inlined into the JS bundle).
ARG NEXT_PUBLIC_API_URL=http://localhost
ARG NEXT_PUBLIC_SOCKET_URL=http://localhost
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL \
    NEXT_PUBLIC_SOCKET_URL=$NEXT_PUBLIC_SOCKET_URL \
    NEXT_TELEMETRY_DISABLED=1

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

# --- runtime stage -----------------------------------------------------------
FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production \
    PORT=3001 \
    NEXT_TELEMETRY_DISABLED=1

RUN apk add --no-cache libc6-compat

# Same public config at runtime (some server components may read it).
ARG NEXT_PUBLIC_API_URL=http://localhost
ARG NEXT_PUBLIC_SOCKET_URL=http://localhost
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL \
    NEXT_PUBLIC_SOCKET_URL=$NEXT_PUBLIC_SOCKET_URL

# Copy the installed deps + build output + public assets + config.
# (No `output: "standalone"` is configured in the app, so we ship node_modules.)
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/public ./public
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/next.config.ts ./next.config.ts

USER node

EXPOSE 3001

CMD ["npm", "run", "start"]
