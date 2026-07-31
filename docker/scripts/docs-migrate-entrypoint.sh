#!/bin/sh
# docs-migrate-entrypoint.sh — Bootstrap the base schema (first run) then
# apply incremental upgrade migrations before starting octo-docs-backend.
#
# Mounted read-only into the octo-docs-backend container by docker-compose.yaml
# and invoked as the service's `command:`. Keeps compose.yaml clean while
# delivering a two-phase startup sequence:
#
#   Phase 1 — base schema bootstrap (idempotent):
#     Checks whether `doc_meta` exists. If not, imports migrations/schema.sql.
#     `doc_meta` is the first table created by schema.sql and serves as the
#     presence sentinel. The check uses only information_schema (always present)
#     so it never fails on a genuinely empty database.
#
#   Phase 2 — incremental upgrades (idempotent):
#     Runs `node dist/db/migrate.js`, which applies any pending files under
#     /app/migrations/upgrades/ with an advisory lock + schema_migrations
#     ledger. Already-applied files are skipped.
#
#   Phase 3 — exec the API server:
#     `exec node dist/index.js` replaces this shell so SIGTERM reaches Node
#     directly (graceful shutdown).
#
# MINIMUM IMAGE VERSION: octo-docs-backend >= 0.3.0
#   (first tag to ship /app/dist/db/migrate.js and /app/migrations/upgrades/).
set -e

# ── Phase 1: base schema bootstrap ──────────────────────────────────────────
node - <<'JS'
const mysql = require('mysql2/promise');
const fs    = require('fs');

async function main() {
  const conn = await mysql.createConnection({
    host:               process.env.MYSQL_HOST     || 'mysql',
    port:               Number(process.env.MYSQL_PORT) || 3306,
    user:               process.env.MYSQL_USER,
    password:           process.env.MYSQL_PASSWORD,
    database:           process.env.MYSQL_DATABASE,
    multipleStatements: true,
  });

  const [[row]] = await conn.query(
    "SELECT COUNT(*) AS cnt FROM information_schema.tables " +
    "WHERE table_schema = ? AND table_name = 'doc_meta'",
    [process.env.MYSQL_DATABASE]
  );

  if (row.cnt === 0) {
    console.log('[docs-init] doc_meta absent — importing schema.sql');
    const sql = fs.readFileSync('/app/migrations/schema.sql', 'utf8');
    await conn.query(sql);
    console.log('[docs-init] schema.sql imported successfully');
  } else {
    console.log('[docs-init] schema already present, skipping schema.sql');
  }

  await conn.end();
}

main().catch(err => {
  console.error('[docs-init] FATAL: schema bootstrap failed:', err.message);
  process.exit(1);
});
JS

# ── Phase 2: incremental upgrade migrations ──────────────────────────────────
node dist/db/migrate.js

# ── Phase 3: start the API server ────────────────────────────────────────────
exec node dist/index.js
