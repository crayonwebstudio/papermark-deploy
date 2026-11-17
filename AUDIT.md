# Papermark self-host audit for paper.woodwolfdigital.com

Audited: 2026-11-17. Source inspected: `papermark/papermark` main, commit `ed19717ec02a1ac79aecf5569159aa9d2d869312` (2026-08-28, message: "fix(groups): keep existing domains when adding another"). Note: the repo moved from `mfts/papermark` to the `papermark` org; the old URL redirects.

Method: the sandbox on this VM blocks `git clone` (O_EXCL lock files return EPERM) and blocks child-process file writes, so the source was inspected by streaming the GitHub main tarball and extracting individual files to stdout, plus the GitHub API and the published npm bundles for `@upstash/redis`, `@upstash/qstash`, `@chronark/zod-bird` and `stripe` to settle constructor behaviour. The four draft patches were verified mechanically against the pinned commit with `~/workspace/papermark-audit/verify-patches.py`: all 12 hunks match (context plus removed lines) and all hunk header counts are correct. No repo, Coolify project, app, or deploy was created. No live env was set. Draft deploy files are in `~/workspace/papermark-deploy/`.

## 1. What Papermark is, in this repo

Next.js 14.2.35 (App Router plus Pages API routes), React 18.3.1, Prisma 6.5.0, PostgreSQL, NextAuth with the Prisma adapter. Engines field: `node >= 24`. No official Dockerfile or Compose file in the repo. The `vercel-build` script is `prisma migrate deploy && next build`. There is a `pages/api/health.ts` that runs `SELECT 1` against Postgres, usable as a container healthcheck.

License (read, not assumed): the repo root is AGPLv3, BUT everything under `ee/` and `app/(ee)/` is under the Papermark Commercial License (`ee/LICENSE.md`). That license says the ee software "may only be used in production" with a valid Papermark Enterprise Edition subscription, and the ee README warns against hosting your own copy of app.papermark.com without a license. Development and testing use is allowed without a subscription. This matters because ee code is not a side plugin, it is woven through the core: the S3 storage layer (`ee/features/storage`), plan limits (`ee/limits`), billing (`ee/stripe`), security rate limiting (`ee/features/security`), SAML, data rooms, AI, and conversations are all ee. A production self-host of main as-is therefore needs an Enterprise subscription decision from milan before it goes live. See Decisions, item 0.

## 2. Auth: providers, and how the first admin is created

`lib/auth/auth-options.ts` registers: Google, LinkedIn, Email (magic link), Passkey (Hanko), and SAML (ee, BoxyHQ). There is NO email/password provider. The login and register pages offer only: Continue with Email, Continue with Google, Continue with LinkedIn, Continue with a passkey.

First login flow (no seed admin, no bootstrap user, no CLI user creation in the repo):
1. Open `https://paper.woodwolfdigital.com/register`.
2. Enter an email and get a magic link, or continue with Google/LinkedIn.
3. The first account then goes through onboarding and creates the first team. `Team.plan` defaults to `"free"` in the Prisma schema.

Consequences:
- With Google OAuth configured, first login works with no other external service.
- With email magic link, login needs Resend AND Upstash Redis (see sections 4 and 5). Without either, the email path fails.
- Passkey login needs Hanko keys. Without them, login itself breaks (see section 3, blocker 1).

## 3. Hard blockers found in current main (verified in code)

These are not missing nice-to-haves. Each one breaks the app on a self-hosted domain unless fixed by env or by patch. The draft Dockerfile applies patches for all four (see `patches/`).

### Blocker 1: Hanko keys are required for ANY login, not just passkeys

`lib/hanko.ts` throws at import time when `HANKO_API_KEY` or `NEXT_PUBLIC_HANKO_TENANT_ID` is unset:

```ts
if (!process.env.HANKO_API_KEY || !process.env.NEXT_PUBLIC_HANKO_TENANT_ID) {
  throw new Error("Please set HANKO_API_KEY and NEXT_PUBLIC_HANKO_TENANT_ID ...");
}
```

`lib/auth/auth-options.ts` imports that module, and `pages/api/auth/[...nextauth].ts` imports auth-options. So without Hanko keys, every `/api/auth/*` request throws at import and login returns 500. The `.env.example` comment ("required for signup with passkey") understates this. Fix options: create a free Hanko Cloud account and set both keys, or apply patch `03-hanko-optional.patch`, which makes the passkey provider conditional and skips it when the keys are absent.

### Blocker 2: the middleware treats our own domain as a visitor custom domain

`middleware.ts` decides what is a custom link domain with a hardcoded list:

```ts
function isCustomDomain(host: string) {
  return (
    (process.env.NODE_ENV === "development" &&
      (host?.includes(".local") || host?.includes("papermark.dev"))) ||
    (process.env.NODE_ENV !== "development" &&
      !(
        host?.includes("localhost") ||
        host?.includes("papermark.io") ||
        host?.includes("papermark.com") ||
        host?.endsWith(".vercel.app")
      ))
  );
}
```

`paper.woodwolfdigital.com` matches none of those, so it is treated as a custom domain. `lib/middleware/domain.ts` then redirects `/` to `https://www.papermark.com` and rewrites every other path to `/view/domains/<host><path>`. The dashboard and login would never render. On top of that, DomainMiddleware calls `getDomainRedirectUrl()`, which does an unguarded `redis.get()` against Upstash REST, so with no Upstash configured the request throws and returns 500 instead of even redirecting. There is no env var to override this (the `NEXT_PUBLIC_APP_BASE_HOST` in `.env.example` is not read anywhere in the code). Patch `01-middleware-app-host.patch` makes the app host, taken from `NEXTAUTH_URL`, exempt. Note: middleware env is inlined at build time, so `NEXTAUTH_URL` must be set as a Docker build arg as well as a runtime var.

### Blocker 3: S3 storage config throws unless four vars are set, and the archive bucket is undocumented

`ee/features/storage/config.ts` `getStorageConfig()` throws when any of these is missing: `NEXT_PRIVATE_UPLOAD_BUCKET`, `NEXT_PRIVATE_UPLOAD_ACCESS_KEY_ID`, `NEXT_PRIVATE_UPLOAD_SECRET_ACCESS_KEY`, `NEXT_PRIVATE_ARCHIVE_BUCKET`. The archive bucket is required by code but does NOT appear in `.env.example`. The tus upload route constructs `new MultiRegionS3Store()` at import, which calls `getStorageConfig()`, so uploads fail without all four. `NEXT_PUBLIC_UPLOAD_TRANSPORT` must be `"s3"`; the default `"vercel"` makes `getS3Client()` throw "Invalid upload transport" and the upload routes reject with "Unsupported upload transport: document uploads require NEXT_PUBLIC_UPLOAD_TRANSPORT=s3".

### Blocker 4: MinIO endpoint is ignored by the main upload path

`ee/features/storage/s3-store.ts` builds its S3 clients with only bucket, region, and credentials. It never passes `endpoint` and never sets `forcePathStyle`, even though `config.ts` reads `NEXT_PRIVATE_UPLOAD_ENDPOINT`. So document uploads through tus go to the real AWS S3 endpoint regardless of `NEXT_PRIVATE_UPLOAD_ENDPOINT`. Only the presigned-URL helpers in `lib/files/aws-client.ts` pass the endpoint, and they also omit `forcePathStyle`, so MinIO gets virtual-host style URLs (`<bucket>.minio:9000`) which fail without bucket DNS. Patch `02-s3-minio-endpoint.patch` adds the endpoint plus `forcePathStyle: true` in both files. With the patch, MinIO works for uploads, but viewers and downloads still need a PUBLIC MinIO endpoint: presigned GET URLs are built from the S3 endpoint host (`pages/api/file/s3/get-presigned-get-url.ts` falls through to `getS3SignedUrl` when no CloudFront distribution host is set), and those URLs are fetched by the visitor browser. An internal `http://minio:9000` endpoint produces unreachable viewer URLs. The draft stack therefore exposes MinIO at `https://s3.paper.woodwolfdigital.com` and points `NEXT_PRIVATE_UPLOAD_ENDPOINT` at that public URL. AWS S3 avoids this whole problem and needs no storage patch, but it is a paid external dependency.

## 4. Email (Resend)

`lib/resend.ts`: `resend` is null without `RESEND_API_KEY`, and `sendEmail()` throws "Resend not initialized". Consequences without Resend: email magic-link login fails, team invites fail, view notifications, dataroom digests, and all other emails fail. Google/LinkedIn login still works.

Extra catch: the magic-link path also needs Upstash Redis. `lib/emails/send-verification-request.ts` does `await redis.set(...)` to store the 10-character login code (15 minute TTL) BEFORE sending the email. With no Upstash Redis configured, that `redis.set` throws and the magic link is never sent, even with a valid Resend key. Email login therefore needs BOTH Resend and Upstash Redis (REST), or a code patch to store login codes elsewhere.

Also note the default sender addresses in `lib/resend.ts` are Papermark addresses (`system@papermark.com`, `system@verify.papermark.com`, `marc@papermark.com`). Resend only sends from domains verified in your Resend account, so even with a key, verification mail may fail unless the sender is changed or the domain is verified. The verification sender is not overridden by any env var in the code path read; check this at deploy time if email login is chosen.

## 5. Upstash Redis: a local redis container CANNOT substitute for it

`lib/redis.ts` constructs two `@upstash/redis` clients (REST/HTTP, not the Redis wire protocol):

```ts
export const redis = new Redis({ url: process.env.UPSTASH_REDIS_REST_URL, ... });
export const lockerRedisClient = new Redis({ url: process.env.UPSTASH_REDIS_REST_LOCKER_URL, ... });
```

A `redis:7-alpine` service speaks the wire protocol and cannot answer Upstash REST calls. The avnox compose includes one anyway (see section 9); it does nothing for this app.

Verified constructor behaviour (from the published bundles): `new Redis()` with undefined url/token does NOT throw at construction; requests fail later. `new Client()` from `@upstash/qstash` v2 only warns on a missing token. So the app boots without Upstash, and the damage is per-feature:

- Tus upload locker: `pages/api/file/tus/[[...file]].ts` and `pages/api/file/tus-viewer/[[...file]].ts` both build a `RedisLocker` from `lockerRedisClient`. On upload, lock acquisition does a REST `SET NX`. Without Upstash, uploads fail. Patch `04-tus-locker-optional.patch` makes the locker a no-op when `UPSTASH_REDIS_REST_LOCKER_URL` is unset. That is safe only with a single app replica (the draft runs 1 replica) and low concurrency, which fits milan's use. The alternative is a free Upstash account, which removes the need for this patch.
- Email login codes: stored in the main `redis` client (see section 4). No Upstash means no email login.
- Rate limiting: `ee/features/security/lib/ratelimit.ts` `checkRateLimit()` catches errors and fails OPEN, so auth still works without Redis.
- Custom-domain redirects: `lib/api/domains/redis.ts` does unguarded `redis.get()`. Only reachable through DomainMiddleware, which patch 01 routes around for the app host.
- Feature flags: `lib/featureFlags/index.ts` reads Vercel Edge Config with try/catch and degrades to "all beta flags off" when it is absent. No Edge Config needed.

## 6. Analytics (Tinybird)

`lib/tinybird/publish.ts` and `pipes.ts` both do `new Tinybird({ token: process.env.TINYBIRD_TOKEN })`. Verified from the `@chronark/zod-bird` bundle: the constructor does not throw on a missing token; ingest calls throw on request failure. The view-recording route (`app/api/views/route.ts`) records the view in Postgres and calls `publishPageView(...).catch(...)`, so a failed ingest does not break the view. Without Tinybird: the app boots and serves documents, but per-page view duration, completion stats, and the analytics dashboards have no data (pipe reads fail). There is no Postgres-backed analytics fallback in the code. Tinybird has a free tier; that is the only supported way to get view analytics. The Tinybird datasources and pipes live in `lib/tinybird/datasources/` and would also need to be deployed to a Tinybird account (`tb push`) for the pipes to exist; a bare token with no pipes still returns errors.

PostHog/Jitsu product analytics degrade cleanly: `lib/analytics/index.ts` uses `emptyAnalytics` when `JITSU_HOST`/`JITSU_WRITE_KEY` are unset, and PostHog capture is a no-op when not configured. The `/ingest/*` PostHog proxy middleware just forwards to PostHog's EU host.

## 7. Background jobs: QStash and Trigger.dev

- QStash: used in exactly two places, both in the outgoing-webhook flow (`publishWebhookEventToQStash` and its fan-out caller). Without `QSTASH_TOKEN`, user-configured webhooks fail; nothing else uses QStash. The cron routes under `app/api/cron/` (dataroom digest daily/weekly, welcome-user, domains, year-in-review) verify the QStash signature only when `VERCEL === "1"` (`lib/cron/verify-qstash.ts` skips verification otherwise), so on Coolify they can be driven by Coolify scheduled tasks hitting the endpoints directly. No QStash account needed for those.
- Trigger.dev: tasks exist only for ee background work (AI document indexing, conversation notifications, dataroom freeze archiving, billing pause/resume). `TRIGGER_SECRET_KEY` is not needed for core document sharing. The app boots and works without it; AI features and those notifications do not run.

## 8. Billing (Stripe) and plan limits

`ee/stripe/index.ts` does `new Stripe(process.env.STRIPE_SECRET_KEY_LIVE ?? process.env.STRIPE_SECRET_KEY ?? "")` at import. Verified against stripe-node 18.5.0: an empty key throws `Neither apiKey nor config.authenticator provided` at construction. So any route importing `@/ee/stripe` (billing settings, Stripe webhook, checkout, team deletion via `cancelSubscription`) returns 500 without Stripe keys. Core routes do not import it. Plan limits are DB-driven (`ee/limits/server.ts`, `ee/limits/constants.ts`) and default to the free plan, so the app works without Stripe on free limits:

- Free plan: 1 user, 50 links, 50 documents, 0 custom domains, 0 data rooms. Document 100 MB, 100 pages max; image 30 MB; video 500 MB; 150 files max per upload.
- Data rooms and custom link domains are 0 on free. `Team.plan` is a plain string column defaulting to `"free"`, so an admin can raise it with a Postgres `UPDATE teams SET plan = 'business'` to unlock data rooms and domains. That is an undocumented manual step, not a supported flow, and it is also where the ee Commercial License question bites (data rooms are ee features).
- There is no in-app upgrade path without Stripe; plans are set by Stripe webhooks.

## 9. Custom domains (link domains) and Vercel integration

`lib/domains.ts` calls `api.vercel.com` with `PROJECT_ID_VERCEL`, `TEAM_ID_VERCEL`, `AUTH_BEARER_TOKEN` to add, verify, and remove link domains. Without those vars, adding a custom link domain fails. The free plan allows 0 domains anyway, so this is moot on day 1. Vercel Blob is not used when transport is `s3`. Vercel Edge Config is not needed (flags degrade to off). No Vercel account is required for the core app.

## 10. The avnox community image: verdict is DO NOT USE

Checked `avnox-com/papermark-self-host` and `ghcr.io/avnox-com/papermark:latest` on 2026-11-17:

- Image exists. Tags: `latest`, `sha-d6a12777d41d`, `sha-84474137f98e`. The `sha-` tags are the avnox repo's own commit SHAs, not Papermark commits, so they say nothing about the Papermark version inside.
- Image config `created`: 2026-04-26, Node 22.22.2, workdir `/app`, port 3000, no labels, no recorded upstream commit. Current main needs Node `>= 24` and its latest commit is 2026-08-28, so the image is roughly 4 months of upstream commits stale and one major Node version behind. Last avnox repo commit is 2025-12-20 despite a scheduled rebuild every 3 days, so the image is not being rebuilt.
- Its `.env.example` uses env names that DO NOT EXIST in current main: `BLOB_STORAGE_TYPE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET_NAME`, `S3_ENDPOINT`, `S3_FORCE_PATH_STYLE`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `REDIS_URL`, `EMAIL_FROM`, `TINYBIRD_API_URL`, `NEXT_PUBLIC_ENABLE_ANALYTICS`, `NEXT_PUBLIC_ENABLE_CUSTOM_DOMAINS`. Current main reads `NEXT_PRIVATE_UPLOAD_BUCKET`, `NEXT_PRIVATE_UPLOAD_ACCESS_KEY_ID`, `NEXT_PRIVATE_UPLOAD_SECRET_ACCESS_KEY`, `NEXT_PRIVATE_UPLOAD_ENDPOINT`, `NEXT_PUBLIC_UPLOAD_TRANSPORT`, and has no GitHub provider, no `REDIS_URL` reader, and no `BLOB_STORAGE_TYPE`. A stack built from its compose would leave the real vars unset.
- Its Dockerfile is Node 20 in the file (build arg overrides to 22), copies a `next.config.docker.js` over `next.config.js` while current main uses `next.config.mjs` (the override is ignored or replaces the wrong file, losing the upstream rewrites for `/oauth/*` and `/.well-known/*`), runs `node server.js` without a standalone build, and uses `prisma db push` instead of migrations.
- Its compose is Docker Swarm only: overlay networks, `deploy.placement.constraints` (e.g. `node.labels.papermark.postgres == true`), Traefik labels, 2 replicas. None of that works in a Coolify compose app.
- It includes `redis:7-alpine` as a cache and claims leaving `UPSTASH_REDIS_REST_URL` empty falls back to it. False: nothing bridges local Redis to the Upstash REST client.
- It does not patch `middleware.ts`, so the custom-domain redirect problem in section 3 applies to it as well.
- It also does not solve the Hanko throw, the missing archive bucket, or the MinIO endpoint problem.

Recommendation: build our own image from official source at the pinned commit, with the four patches in `patches/`. That is what the draft Dockerfile does.

## 11. Recommended stack

- App: own build from `papermark/papermark` at pinned commit `ed19717e`, Node 24, `npm ci`, `prisma generate`, `next build`, `next start` on port 3000, entrypoint runs `prisma migrate deploy` first. Four patches applied at build time (see `patches/` and section 3).
- Postgres: `postgres:16-alpine`, named volume, `pg_isready` healthcheck.
- Storage: MinIO (`minio/minio:latest`) in the same stack, buckets `papermark` and `papermark-archive` created by a one-shot `minio/mc` init service, public S3 endpoint at `https://s3.paper.woodwolfdigital.com` (Coolify domain on the minio service), `forcePathStyle` via patch 02.
- No local Redis service (it cannot serve Upstash REST; the locker is patched to no-op, rate limiting fails open).
- No QStash, Trigger, Tinybird, Stripe, or Vercel accounts on day 1. Google OAuth is the only external account needed for login.
- Coolify: docker-compose build pack, domain `paper.woodwolfdigital.com` on the app service in the Coolify UI, TLS via Coolify/Traefik. No Swarm blocks, no Traefik labels, no published ports in the compose file (Coolify injects routing). Precedent checked: `~/workspace/whatscrm-push/docker-compose.yml` (live Coolify app: `build: .`, no ports, no labels, env from Coolify) and `~/workspace/woodwolf-erpnext/docker-compose.yml` (named volumes, healthchecks, `depends_on` with `service_completed_successfully`, one-shot services with `deploy.restart_policy.condition: none`).

## 12. What will NOT work on day 1 (no external accounts)

- Email magic-link login and all emails (needs Resend plus Upstash Redis). Google login works.
- Passkey login (needs Hanko keys, or the patch skips passkeys and login still works via Google).
- View analytics dashboards and per-page stats (needs Tinybird account plus deployed pipes/datasources).
- Outgoing user webhooks (needs QStash).
- Data rooms (free plan allows 0; needs a plan change in Postgres, and data rooms are ee Commercial License features).
- Custom link domains (free plan allows 0; needs Vercel API vars plus a plan change).
- AI document indexing, conversation notifications, dataroom freeze archiving (needs Trigger.dev).
- Billing, checkout, plan upgrades (needs Stripe).
- SAML SSO (ee, needs a BoxyHQ/Jackson setup and a plan that includes SSO).

What WILL work: Google login, first-team onboarding, document upload (tus to MinIO, 100 MB / 100 pages on free), links with view tracking recorded in Postgres (view counts, not durations), link settings (password, expiry, email allow-list), document viewer, downloads, dashboard.

## 13. Decisions milan still needs to make

0. License: ee code is Commercial License, production use requires a Papermark Enterprise subscription per `ee/LICENSE.md`. Decide before going live: buy Enterprise, use it for dev/test only, or accept the position another way. This is the biggest open item and it is not a technical one.
1. Storage: MinIO inside the stack (draft default, needs the public `s3.paper.woodwolfdigital.com` endpoint and patches) vs his AWS S3 Woodwolf account (no storage patches, no public endpoint problem, but an external paid dependency and real AWS keys in Coolify).
2. Login: Google OAuth only (draft default, one Google Cloud OAuth client, zero other accounts) vs email magic link as well (needs Resend account plus Upstash Redis free tier, and the sender-domain question in section 4).
3. Analytics: Tinybird free tier (the only supported way to get view durations and stats) vs none (view counts only, dashboards empty).
4. Upstash: free tier (removes the locker patch need and enables email login and real rate limiting) vs fully self-hosted with the no-op locker patch (draft default).
5. Plan unlock: stay on free limits (1 user, 50 docs, 50 links, no data rooms) vs manually raising `Team.plan` in Postgres (undocumented, and data rooms are ee licensed).
6. Hanko: create a free Hanko account for passkey login vs ship with the patch and no passkeys.
7. Backups: Postgres volume and MinIO volume backup schedule (not in the draft; Coolify has no automatic backup for compose volumes, decide a backup job or accept volume-only persistence).

## 14. Risks

- Patches are against a pinned commit. Any upstream update needs the patches re-verified (they are small and each has a `git apply --check` gate in the Dockerfile, so a bad patch fails the build instead of deploying broken).
- Node 24 is required by engines; the base image must stay on Node 24. Next 14.2.35 on Node 24 is fine, but upstream may move to Next 15/16 later.
- Build size and time: full `node_modules` is copied into the runner (Prisma CLI is needed at runtime for migrations), so the image is large (expect 1 GB plus) and `npm ci` plus `next build` take several minutes on first deploy. Set Coolify's build timeout accordingly.
- `next build` bakes `NEXT_PUBLIC_*` values into the client bundle, so changing the public URL, transport, or Hanko tenant requires a rebuild, not just a restart.
- The upstream main branch has not moved since 2026-08-28 (about 2.5 months at audit time). That is either stability or a quiet period; either way the pinned commit is a known quantity.
- The middleware patch is load-bearing: if it fails to apply, the app redirects its own homepage to papermark.com. The Dockerfile fails the build if any patch does not apply, and the first post-deploy check must be loading `/` and `/login` on the real domain, not just the health endpoint.
- MinIO `latest` tag is unpinned in the draft; pin it at deploy time to the version that was current when the stack is built.
- AGPLv3 applies to the non-ee code: if milan modifies and distributes the app, AGPL obligations apply. Internal self-host use is the usual case here, but it is worth knowing.
