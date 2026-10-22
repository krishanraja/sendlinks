#!/usr/bin/env bash
# Builds a throwaway database with Supabase stubs, applies every migration, runs the SQL tests
# and then the Deno handler tests against the same database.
set -euo pipefail
cd "$(dirname "$0")/.."

DB=${SENDLINKS_TEST_DB:-sendlinks_test}
PGURL=${SENDLINKS_TEST_PGURL:-postgres://postgres:postgres@localhost:5432}

psql "$PGURL/postgres" -qc "drop database if exists $DB" -c "create database $DB"
psql "$PGURL/$DB" -q -v ON_ERROR_STOP=1 -f tests/sql/supabase_stubs.sql
for m in supabase/migrations/*.sql; do
  psql "$PGURL/$DB" -q -v ON_ERROR_STOP=1 -f "$m"
done
psql "$PGURL/$DB" -q -v ON_ERROR_STOP=1 -f tests/sql/sendlinks_test.sql

SENDLINKS_TEST_DB_URL="$PGURL/$DB" deno test --allow-env --allow-net --allow-read supabase/functions/
