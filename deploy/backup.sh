#!/usr/bin/env bash
#
# Minimal backup: Postgres dump + our config layer.
#
# Scope, stated plainly:
#   INCLUDED  - Postgres (projects, users, orgs, issue metadata, settings)
#             - sentry/config.yml, sentry/sentry.conf.py, .env.custom (SECRETS)
#             - relay/credentials.json
#   EXCLUDED  - ClickHouse event bodies. Restoring only this backup gives you a
#               working Sentry with your projects and keys, but not the raw
#               event history. Full event backup means snapshotting the
#               sentry-clickhouse docker volume with the stack stopped.
#
# The output archive CONTAINS SECRETS. Never commit it. Never put it in the repo.
#
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="${SENTRY_BACKUP_DIR:-/var/backups/sentry}"
STAMP="$(date -u +%Y%m%d-%H%M%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT_DIR"

echo "== Postgres dump =="
docker compose exec -T postgres pg_dumpall -U postgres > "$WORK/postgres.sql"
echo "  $(du -h "$WORK/postgres.sql" | cut -f1)"

echo "== Config =="
mkdir -p "$WORK/config/sentry" "$WORK/config/relay"
for f in sentry/config.yml sentry/sentry.conf.py relay/credentials.json .env.custom; do
  if [[ -f "$f" ]]; then
    cp "$f" "$WORK/config/$f" 2>/dev/null || cp "$f" "$WORK/config/$(basename "$f")"
    echo "  $f"
  fi
done

echo "== Version marker =="
git describe --tags --always > "$WORK/VERSION" 2>/dev/null || echo "unknown" > "$WORK/VERSION"
echo "  $(cat "$WORK/VERSION")"

ARCHIVE="$OUT_DIR/sentry-backup-$STAMP.tar.gz"
tar -czf "$ARCHIVE" -C "$WORK" .
chmod 600 "$ARCHIVE"

echo
echo "Wrote $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1), mode 600)"
echo "This archive contains secrets. Store it off-box, encrypted."
