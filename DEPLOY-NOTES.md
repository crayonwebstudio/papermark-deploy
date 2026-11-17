# Papermark deploy notes for paper.woodwolfdigital.com

Read `AUDIT.md` first. This file is the runbook: every env var, the Coolify steps, the first-login flow, and the post-deploy checks. Nothing here has been deployed yet. Do not set any live env until milan has decided the open items in `AUDIT.md` section 13, especially item 0 (the ee Commercial License) and item 1 (MinIO vs AWS S3).

## 1. Architecture

```
paper.woodwolfdigital.com (Coolify/Traefik, TLS)
  -> papermark app (Next.js, port 3000, 1 replica)
       -> postgres:16-alpine (named volume)
       -> minio (S3-compatible, named volume)
            exposed as https://s3.paper.woodwolfdigital.com (Coolify domain on the minio service)
```

No Redis service: local Redis cannot serve the Upstash REST client the app uses. The tus locker is patched to a no-op when Upstash is unset (patch 04), and rate limiting fails open. See `AUDIT.md` section 5.

No QStash, Trigger, Tinybird, Stripe, or Vercel on day 1. Google OAuth is the only external account needed.

## 2. Environment variables

Set these in the Coolify app env vars (never commit real values). Vars marked BUILD must also be set as build args in Coolify, because `NEXT_PUBLIC_*` values and the middleware host check are baked in at build time. Changing a BUILD var needs a rebuild, not just a restart.

Generate secrets with `openssl rand -hex 32` (or `openssl rand -base64 32` for the document password key).

| Variable | Status | Value / notes |
|---|---|---|
| `NEXTAUTH_URL` | REQUIRED, BUILD | `https://paper.woodwolfdigital.com` |
| `NEXTAUTH_SECRET` | REQUIRED | Random 32 byte hex. Session encryption. |
| `NEXT_PUBLIC_BASE_URL` | REQUIRED, BUILD | `https://paper.woodwolfdigital.com` |
| `NEXT_PUBLIC_MARKETING_URL` | OPTIONAL | `https://paper.woodwolfdigital.com` (the app links its own logo to papermark.com otherwise) |
| `NEXT_PUBLIC_APP_BASE_HOST` | OPTIONAL | Not read by the code, set for completeness: `paper.woodwolfdigital.com` |
| `NEXT_PUBLIC_UPLOAD_TRANSPORT` | REQUIRED, BUILD | `s3` (the default `vercel` rejects uploads) |
| `POSTGRES_PRISMA_URL` | REQUIRED | `postgresql://papermark:<password>@postgres:5432/papermark?schema=public` (no PgBouncer in this stack, so the pooled and non-pooling URLs are the same direct DSN) |
| `POSTGRES_PRISMA_URL_NON_POOLING` | REQUIRED | Same DSN as above |
| `POSTGRES_PRISMA_SHADOW_URL` | REQUIRED | Same DSN as above (used by Prisma migrations) |
| `POSTGRES_DB` | REQUIRED | `papermark` |
| `POSTGRES_USER` | REQUIRED | `papermark` |
| `POSTGRES_PASSWORD` | REQUIRED | Random password, also used by the app DSNs above |
| `NEXT_PRIVATE_UPLOAD_BUCKET` | REQUIRED | `papermark` |
| `NEXT_PRIVATE_ARCHIVE_BUCKET` | REQUIRED | `papermark-archive` (required by code, missing from upstream `.env.example`) |
| `NEXT_PRIVATE_UPLOAD_REGION` | REQUIRED | `us-east-1` (must match the MinIO server region, MinIO defaults to us-east-1) |
| `NEXT_PRIVATE_UPLOAD_ACCESS_KEY_ID` | REQUIRED | MinIO root user, or the dedicated user created in MinIO |
| `NEXT_PRIVATE_UPLOAD_SECRET_ACCESS_KEY` | REQUIRED | MinIO root password, or the dedicated user secret |
| `NEXT_PRIVATE_UPLOAD_ENDPOINT` | REQUIRED | `https://s3.paper.woodwolfdigital.com` (the PUBLIC MinIO endpoint, see section 4; an internal `http://minio:9000` breaks viewer URLs in browsers) |
| `NEXT_PRIVATE_UPLOAD_DISTRIBUTION_HOST` | OPTIONAL | Leave empty (no CloudFront). Only set if a CDN fronts the bucket. |
| `NEXT_PRIVATE_UPLOAD_DISTRIBUTION_DOMAIN` | OPTIONAL | Leave empty |
| `NEXT_PRIVATE_UPLOAD_DISTRIBUTION_KEY_ID` | OPTIONAL | Leave empty |
| `NEXT_PRIVATE_UPLOAD_DISTRIBUTION_KEY_CONTENTS` | OPTIONAL | Leave empty |
| `NEXT_PRIVATE_DOCUMENT_PASSWORD_KEY` | REQUIRED | Random string, used to encrypt document passwords |
| `NEXT_PRIVATE_VERIFICATION_SECRET` | REQUIRED | Random string, used for verification URL checksums |
| `INTERNAL_API_KEY` | REQUIRED | Random string. Server-to-server key for the presigned-URL routes. Not in upstream `.env.example`, but the code returns 500 without it. |
| `GOOGLE_CLIENT_ID` | REQUIRED for login | Google Cloud OAuth client ID |
| `GOOGLE_CLIENT_SECRET` | REQUIRED for login | Google Cloud OAuth client secret |
| `LINKEDIN_CLIENT_ID` | OPTIONAL | LinkedIn OAuth, only if milan wants it |
| `LINKEDIN_CLIENT_SECRET` | OPTIONAL | LinkedIn OAuth, only if milan wants it |
| `HANKO_API_KEY` | OPTIONAL | Free Hanko Cloud account. Without it, patch 03 skips passkey login. If set, `NEXT_PUBLIC_HANKO_TENANT_ID` must also be set as a BUILD arg. |
| `NEXT_PUBLIC_HANKO_TENANT_ID` | OPTIONAL, BUILD | Hanko tenant ID, only when Hanko is used |
| `MINIO_ROOT_USER` | REQUIRED | MinIO root user, e.g. `papermark` |
| `MINIO_ROOT_PASSWORD` | REQUIRED | Random password, also used as the app S3 secret when using root creds |
| `MINIO_PUBLIC_HOST` | REQUIRED | `s3.paper.woodwolfdigital.com` (used for the `extra_hosts` entry so the app container reaches MinIO through Traefik) |
| `RESEND_API_KEY` | DEGRADED WITHOUT | Without it: no email login, no invites, no notification emails. Needs a Resend account plus Upstash Redis for the login-code round trip (see `AUDIT.md` section 4). |
| `UPSTASH_REDIS_REST_URL` | DEGRADED WITHOUT | Upstash Redis REST URL. Without it: no email login codes, rate limiting fails open (safe), domain redirects unavailable (not used after patch 01). |
| `UPSTASH_REDIS_REST_TOKEN` | DEGRADED WITHOUT | Upstash Redis REST token. |
| `UPSTASH_REDIS_REST_LOCKER_URL` | DEGRADED WITHOUT | Without it, patch 04 makes the tus locker a no-op (safe at 1 replica). With it, the patch is inert and the real locker is used. |
| `UPSTASH_REDIS_REST_LOCKER_TOKEN` | DEGRADED WITHOUT | Token for the locker Redis. |
| `TINYBIRD_TOKEN` | DEGRADED WITHOUT | Without it: no view durations or analytics dashboards. Needs a Tinybird account with the pipes/datasources in `lib/tinybird/` deployed. |
| `TINYBIRD_BASE_URL` | OPTIONAL | Only when using a non-default Tinybird region. |
| `QSTASH_TOKEN` | DEGRADED WITHOUT | Without it: outgoing user webhooks fail. |
| `QSTASH_CURRENT_SIGNING_KEY` | OPTIONAL | Only with QStash. |
| `QSTASH_NEXT_SIGNING_KEY` | OPTIONAL | Only with QStash. |
| `TRIGGER_SECRET_KEY` | DEGRADED WITHOUT | Without it: no AI indexing, no conversation notifications, no dataroom freeze jobs. |
| `STRIPE_SECRET_KEY` | DEGRADED WITHOUT | Without it: billing pages and the Stripe webhook return 500. Core app unaffected. No in-app upgrade path without Stripe. |
| `STRIPE_WEBHOOK_SECRET` | OPTIONAL | Only with Stripe. |
| `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` | OPTIONAL | Only with Stripe. |
| `PROJECT_ID_VERCEL` | DEGRADED WITHOUT | Without it: adding custom link domains fails. Free plan allows 0 domains anyway. |
| `TEAM_ID_VERCEL` | DEGRADED WITHOUT | Same as above. |
| `AUTH_BEARER_TOKEN` | DEGRADED WITHOUT | Same as above. |
| `BLOB_READ_WRITE_TOKEN` | NOT USED | Only for Vercel Blob transport. Leave unset when transport is `s3`. |
| `NODE_ENV` | REQUIRED | `production` |
| `PORT` | REQUIRED | `3000` |
| `HOSTNAME` | REQUIRED | `0.0.0.0` |

Vars the avnox compose sets that this app does NOT read (do not set them, they do nothing): `BLOB_STORAGE_TYPE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `AWS_S3_BUCKET_NAME`, `S3_ENDPOINT`, `S3_FORCE_PATH_STYLE`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `REDIS_URL`, `EMAIL_FROM`, `TINYBIRD_API_URL`, `NEXT_PUBLIC_ENABLE_ANALYTICS`, `NEXT_PUBLIC_ENABLE_CUSTOM_DOMAINS`, `DATABASE_URL`.

## 3. Coolify steps (to be done by the parent agent, not this audit)

1. Create a GitHub repo for the deploy files in this directory (Dockerfile, docker-compose.yml, patches, entrypoint, .env.example). Do not put real secrets in it.
2. Create a Coolify project (suggested name: `papermark`) and a Docker Compose app from that repo on the Woodwolf server.
3. In the Coolify app, set the domain `paper.woodwolfdigital.com` on the `papermark` service. Set a second domain `s3.paper.woodwolfdigital.com` on the `minio` service. Both get TLS from Coolify/Traefik.
4. Set every REQUIRED env var from section 2 in the Coolify env vars. Set the BUILD vars as build args too (Coolify build-time variables), with the same values.
5. Deploy. First build takes several minutes (`npm ci` plus `next build`); allow a long build timeout.
6. Run the post-deploy checks in section 6 before telling milan it is ready.

## 4. MinIO public endpoint, and why it is needed

Document viewers and downloads use presigned S3 URLs built from `NEXT_PRIVATE_UPLOAD_ENDPOINT`, and those URLs are fetched by the visitor browser. So the endpoint must be a public URL, not `http://minio:9000`. The stack exposes MinIO at `https://s3.paper.woodwolfdigital.com` through Traefik. The app container reaches that same public URL from inside Docker; the compose file pins the hostname to the Docker host gateway with `extra_hosts` so the request hits Traefik instead of depending on hairpin NAT. If that proves flaky, the fallback is to point `extra_hosts` at the server public IP, or to switch storage to AWS S3 (decision 1 in `AUDIT.md`).

The `minio-init` one-shot service creates the `papermark` and `papermark-archive` buckets at first deploy. Buckets stay private; access is only through presigned URLs. The MinIO console (port 9001) is not exposed by default; add a Coolify domain for it only if milan wants console access.

## 5. First-login flow (for milan, after deploy)

1. Open `https://paper.woodwolfdigital.com/register`.
2. Click "Continue with Google" and sign in with the Google account that owns the OAuth client. (Email magic link is not available unless Resend plus Upstash are configured.)
3. Complete onboarding; this creates the first team. The team starts on the free plan: 1 user, 50 documents, 50 links, no data rooms, no custom domains.
4. Upload a test document and open its link in a private window to confirm the viewer works end to end.
5. If milan wants more than free limits, the plan is a plain string in Postgres (`teams.plan`); raising it is a manual `UPDATE` and also touches the ee license question, so do not do it silently. Ask first.

## 6. Post-deploy checks (must all pass before calling it done)

1. `https://paper.woodwolfdigital.com/api/health` returns `{"status":"ok",...}` (DB check).
2. `https://paper.woodwolfdigital.com/` redirects to `/login` (NOT to `https://www.papermark.com`; that redirect means patch 01 did not apply).
3. `https://paper.woodwolfdigital.com/login` renders with Google, Email, LinkedIn, and passkey buttons.
4. Google login completes and lands on `/dashboard` (or onboarding for the first user).
5. Upload a PDF (small, under 100 MB) and confirm it processes and shows a page count.
6. Create a link, open it in a private window, and confirm the document renders (this proves the presigned MinIO URL works from a browser).
7. Download the document from the viewer (proves presigned GET works).
8. Check the app logs for repeated `Missing environment variable` errors (storage config) and for Hanko throw errors (should be none after patch 03).
9. Confirm `https://s3.paper.woodwolfdigital.com/minio/health/live` returns 200 (proves the public MinIO endpoint is reachable).

## 7. What to do when something breaks

- Login page 500s: check for the Hanko throw in the logs (patch 03 did not apply, or the build used a different commit), or a missing `NEXTAUTH_SECRET`.
- `/` redirects to papermark.com: patch 01 did not apply, or `NEXTAUTH_URL` was not set as a build arg so the middleware baked in the wrong host. Rebuild with the build arg set.
- Upload fails immediately: check the storage env vars (all four, including the archive bucket) and that `NEXT_PUBLIC_UPLOAD_TRANSPORT=s3` was set at build time (it is baked into the client bundle; changing it needs a rebuild).
- Viewer shows a blank document or download fails: the presigned URL host is unreachable from the browser. Check `NEXT_PRIVATE_UPLOAD_ENDPOINT` is the public `https://s3.paper.woodwolfdigital.com` and that the subdomain resolves and serves TLS.
- Upload hangs or fails mid-way: the tus locker. If Upstash locker vars are unset, patch 04 should make it a no-op; check the patch applied and that only 1 replica is running.
- Health endpoint 500s: Postgres is down or the DSNs are wrong. Check `POSTGRES_PRISMA_URL` (the app reads that, not `DATABASE_URL`).

## 8. Backups (not in the draft)

The Postgres volume (`papermark-postgres-data`) and the MinIO volume (`papermark-minio-data`) are the only state. There is no backup job in the compose file. Before this holds real documents, decide a backup: a Coolify scheduled task running `pg_dump` plus an `mc mirror` of the buckets to an off-server location, or a host-level volume backup. Do not rely on "the volumes exist" as a backup.
