# Papermark deploy repo (draft, not deployed)

Self-host Papermark on `paper.woodwolfdigital.com` with Coolify. See `AUDIT.md`
for the full findings first; this README is only the map of the files.

## Files

- `AUDIT.md`: the audit. Findings per area, the avnox verdict, the recommended
  stack, what will not work on day 1, the decisions milan still needs to make,
  and the risks.
- `DEPLOY-NOTES.md`: the runbook. Every env var as REQUIRED / OPTIONAL /
  DEGRADED-WITHOUT, the Coolify steps, the MinIO public endpoint reasoning,
  the first-login flow, the post-deploy checks, and what to do when it breaks.
- `.env.example`: the env template for the Coolify env vars.
- `Dockerfile`: multi-stage Node 24 build. Clones `papermark/papermark` at the
  pinned commit `ed19717e`, applies `patches/*.patch` (the build fails if any
  patch does not apply), `npm ci`, `prisma generate`, `next build`, then a
  slim runner that runs `prisma migrate deploy` on start and serves on 3000.
- `docker-compose.yml`: services `papermark`, `postgres:16-alpine`, `minio`,
  `minio-init` (one-shot bucket creation). No Redis service, no published
  ports, no Traefik labels, no Swarm blocks. Coolify sets the domains
  (`paper.woodwolfdigital.com` on papermark, `s3.paper.woodwolfdigital.com`
  on minio) in the UI.
- `docker-entrypoint.sh`: retries `prisma migrate deploy`, then `npm run start`.
- `patches/`: the four patches that make current main work self-hosted.
  Each file explains why it exists. All hunks were verified against the
  pinned commit with `~/workspace/papermark-audit/verify-patches.py`
  (all 12 hunks OK on 2026-11-17).
  - `01-middleware-app-host.patch`: the app host is not a visitor custom domain.
  - `02-s3-minio-endpoint.patch`: honour the MinIO endpoint, path-style S3.
  - `03-hanko-optional.patch`: passkeys optional, login works without Hanko.
  - `04-tus-locker-optional.patch`: tus locker no-ops without Upstash Redis.

## Status

Draft only. No GitHub repo, no Coolify project or app, no deploy, no live env
was created by this audit. The open decisions in `AUDIT.md` section 13
(especially item 0, the ee Commercial License, and item 1, MinIO vs AWS S3)
must be decided before any deploy.
