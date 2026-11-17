# syntax=docker/dockerfile:1
# Papermark self-hosted build for Coolify (paper.woodwolfdigital.com)
#
# Builds the official papermark/papermark source at a pinned commit and
# applies the local patches in ./patches (see AUDIT.md section 3 for why
# each patch exists). The build FAILS if any patch does not apply, so a
# stale patch can never silently deploy.
#
# Build-time args (set the same values as Coolify build-time variables):
#   NEXTAUTH_URL, NEXT_PUBLIC_BASE_URL, NEXT_PUBLIC_UPLOAD_TRANSPORT,
#   NEXT_PUBLIC_HANKO_TENANT_ID
# These are baked into the client bundle and into the edge middleware.
# Changing them needs a rebuild, not just a restart.

ARG NODE_VERSION=24
ARG PAPERMARK_REF=ed19717ec02a1ac79aecf5569159aa9d2d869312

# ---------------------------------------------------------------------------
# Stage 1: fetch source, apply patches, install, build
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS builder

RUN apk add --no-cache \
    git \
    openssl \
    libc6-compat \
    python3 \
    make \
    g++ \
    curl

WORKDIR /app

ARG PAPERMARK_REF
# Shallow-fetch the exact pinned commit (GitHub allows fetching a SHA directly).
RUN git init -q \
    && git remote add origin https://github.com/papermark/papermark.git \
    && git fetch --depth 1 origin ${PAPERMARK_REF} \
    && git checkout -q FETCH_HEAD \
    && git log --oneline -1

# Patches that make current main work self-hosted (see patches/*.patch headers).
COPY patches ./patches
RUN git apply --check patches/*.patch && git apply --verbose patches/*.patch

# Build-time public env (baked into the client bundle and the middleware).
ARG NEXTAUTH_URL=https://paper.woodwolfdigital.com
ARG NEXT_PUBLIC_BASE_URL=https://paper.woodwolfdigital.com
ARG NEXT_PUBLIC_UPLOAD_TRANSPORT=s3
ARG NEXT_PUBLIC_HANKO_TENANT_ID=dummy
ENV NEXT_TELEMETRY_DISABLED=1 \
    NODE_ENV=production \
    NEXTAUTH_URL=${NEXTAUTH_URL} \
    NEXT_PUBLIC_BASE_URL=${NEXT_PUBLIC_BASE_URL} \
    NEXT_PUBLIC_MARKETING_URL=${NEXT_PUBLIC_BASE_URL} \
    NEXT_PUBLIC_UPLOAD_TRANSPORT=${NEXT_PUBLIC_UPLOAD_TRANSPORT} \
    NEXT_PUBLIC_HANKO_TENANT_ID=${NEXT_PUBLIC_HANKO_TENANT_ID}

# Dummy server-only values so `next build` can collect page data without a
# live database or real secrets. Real values come from the runtime env.
ENV NEXTAUTH_SECRET=build-time-dummy-secret \
    POSTGRES_PRISMA_URL=postgresql://dummy:dummy@localhost:5432/dummy?schema=public \
    POSTGRES_PRISMA_URL_NON_POOLING=postgresql://dummy:dummy@localhost:5432/dummy?schema=public \
    POSTGRES_PRISMA_SHADOW_URL=postgresql://dummy:dummy@localhost:5432/dummy?schema=public \
    HANKO_API_KEY=build-time-dummy

RUN npm ci --no-audit --no-fund
RUN npx prisma generate
RUN npm run build

# ---------------------------------------------------------------------------
# Stage 2: production runtime
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS runner

RUN apk add --no-cache libc6-compat openssl curl bash \
    && addgroup --system --gid 1001 nodejs \
    && adduser --system --uid 1001 nextjs

WORKDIR /app

ENV NEXT_TELEMETRY_DISABLED=1 \
    NODE_ENV=production \
    PORT=3000 \
    HOSTNAME=0.0.0.0

# Full node_modules is kept on purpose: the entrypoint runs `prisma migrate
# deploy`, which needs the Prisma CLI at runtime. That makes the image large
# (expect 1 GB plus); see AUDIT.md section 14.
COPY --from=builder /app/package.json /app/package-lock.json ./
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/public ./public
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/next.config.mjs ./next.config.mjs

COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh \
    && chown -R nextjs:nodejs /app

USER nextjs

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:3000/api/health || exit 1

ENTRYPOINT ["/app/docker-entrypoint.sh"]
