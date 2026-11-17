#!/bin/bash
# Papermark entrypoint: run migrations (with retries while Postgres starts),
# then start Next.js.
set -e

echo "Papermark starting..."

# `prisma migrate deploy` fails while Postgres is still starting, so retry it.
# The compose healthcheck usually has Postgres ready already; this loop is
# the second line of defence for slow first boots.
for i in $(seq 1 30); do
  if npx prisma migrate deploy; then
    echo "Migrations applied."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: migrations did not succeed after 30 attempts."
    exit 1
  fi
  echo "Migrations not ready yet (attempt $i/30), retrying in 2s..."
  sleep 2
done

echo "Starting Papermark on port ${PORT:-3000}..."
exec npm run start
