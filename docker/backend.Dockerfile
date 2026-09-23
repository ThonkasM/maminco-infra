# syntax=docker/dockerfile:1
# =============================================================================
# maminco-backend — NestJS + Prisma + socket.io
# Build context: ../maminco-backend   (the app repo; keeps it untouched)
#   docker build -f docker/backend.Dockerfile ../maminco-backend
# =============================================================================

# --- deps / build stage ------------------------------------------------------
FROM node:22-alpine AS builder
WORKDIR /app

# openssl is required by the Prisma query engine on Alpine.
RUN apk add --no-cache openssl

# Install dependencies first for better layer caching.
COPY package.json package-lock.json ./
RUN npm ci

# Generate the Prisma client against the app schema, then compile.
COPY . .
RUN npx prisma generate && npm run build

# --- runtime stage -----------------------------------------------------------
FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
RUN apk add --no-cache openssl

# Copy the fully-installed node_modules (dev deps included on purpose: the
# container needs the prisma CLI + ts-node to run `prisma db push`/`db seed`
# on first boot).
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/prisma.config.ts ./prisma.config.ts
COPY --from=builder /app/tsconfig.json ./tsconfig.json
COPY --from=builder /app/prisma ./prisma

# Run as the non-root `node` user shipped with the base image.
RUN chown -R node:node /app
USER node

EXPOSE 3000

# Overridden by docker-compose to run `prisma db push` + `db seed` first.
CMD ["node", "dist/main"]
