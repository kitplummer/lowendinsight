#!/usr/bin/env bash
#
# Proves the backup role can dump everything the application creates.
#
# Production backups broke when credit_entries landed: the migration created a
# table lei_backup could not read, and pg_dump failed. OPERATIONS.md already
# carried ALTER DEFAULT PRIVILEGES to prevent exactly that, but it was applied
# for the wrong role, so it covered nothing the application created.
#
# That whole failure needs a Postgres, two roles and a pg_dump. It needs nothing
# from Fly, so there is no reason for it to be discovered in production.
#
# Runs locally and in CI against the same Postgres the test suite uses.
#
#   scripts/verify-backup-grants.sh
#
# Requires superuser credentials to create roles. Defaults match config/test.exs.

set -euo pipefail

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
SUPERUSER="${PGSUPERUSER:-postgres}"
SUPERPASS="${PGSUPERPASS:-postgres}"

DB="lei_backup_grant_check_$$"
APP_ROLE="lei_app_check_$$"
BACKUP_ROLE="lei_backup_check_$$"
APP_PASS="app-check-pw"
BACKUP_PASS="backup-check-pw"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
pass() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
fail() { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

as_super() {
  PGPASSWORD="$SUPERPASS" psql -h "$PGHOST" -p "$PGPORT" -U "$SUPERUSER" \
    -v ON_ERROR_STOP=1 -qtAX "$@"
}

cleanup() {
  as_super -d postgres -c "DROP DATABASE IF EXISTS \"$DB\";"            >/dev/null 2>&1 || true
  as_super -d postgres -c "DROP ROLE IF EXISTS \"$BACKUP_ROLE\";"       >/dev/null 2>&1 || true
  as_super -d postgres -c "DROP ROLE IF EXISTS \"$APP_ROLE\";"          >/dev/null 2>&1 || true
}
trap cleanup EXIT

failures=0

bold "Setting up an isolated database with production's role structure"

as_super -d postgres -c "CREATE ROLE \"$APP_ROLE\" LOGIN PASSWORD '$APP_PASS';"       >/dev/null
as_super -d postgres -c "CREATE ROLE \"$BACKUP_ROLE\" LOGIN PASSWORD '$BACKUP_PASS';" >/dev/null
as_super -d postgres -c "CREATE DATABASE \"$DB\" OWNER \"$APP_ROLE\";"                >/dev/null
echo "  database $DB owned by $APP_ROLE"

bold "Running migrations as the application role"

# Migrations run as the app role, exactly as they do in production. This is the
# part that matters: ALTER DEFAULT PRIVILEGES only covers objects created by the
# role it names, so running migrations as a superuser here would hide the bug.
(
  cd "$ROOT/apps/lowendinsight"
  MIX_ENV=test \
  LEI_TEST_DB="$DB" \
  LEI_TEST_DB_USER="$APP_ROLE" \
  LEI_TEST_DB_PASS="$APP_PASS" \
  LEI_TEST_DB_HOST="$PGHOST" \
    mix ecto.migrate >/dev/null
)

TABLES=$(as_super -d "$DB" -c \
  "SELECT count(*) FROM pg_tables WHERE schemaname = 'public';")
echo "  $TABLES tables created"

if [ "$TABLES" -lt 5 ]; then
  fail "only $TABLES tables — migrations did not run"
  exit 1
fi

bold "Applying the grants documented in OPERATIONS.md"

as_super -d "$DB" >/dev/null <<SQL
GRANT CONNECT ON DATABASE "$DB" TO "$BACKUP_ROLE";
GRANT USAGE ON SCHEMA public TO "$BACKUP_ROLE";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "$BACKUP_ROLE";
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO "$BACKUP_ROLE";

-- FOR ROLE is the whole point. Without it these defaults apply only to objects
-- created by the role running this statement, which is not the role that runs
-- migrations.
ALTER DEFAULT PRIVILEGES FOR ROLE "$APP_ROLE" IN SCHEMA public
  GRANT SELECT ON TABLES TO "$BACKUP_ROLE";
ALTER DEFAULT PRIVILEGES FOR ROLE "$APP_ROLE" IN SCHEMA public
  GRANT SELECT ON SEQUENCES TO "$BACKUP_ROLE";
SQL

bold "Every existing table is readable by the backup role"

# OFFSET 0 is an optimisation barrier. Without it the planner is free to
# evaluate has_table_privilege before the schemaname filter, and pg_tables
# includes catalog relations the check then chokes on.
UNREADABLE=$(as_super -d "$DB" -c "
  SELECT string_agg(tablename, ', ')
    FROM (SELECT tablename FROM pg_tables WHERE schemaname = 'public' OFFSET 0) t
   WHERE NOT has_table_privilege('$BACKUP_ROLE', 'public.' || quote_ident(tablename), 'SELECT');")

if [ -z "$UNREADABLE" ]; then
  pass "all $TABLES tables readable"
else
  fail "unreadable: $UNREADABLE"
  failures=$((failures + 1))
fi

bold "A table created after the grants is readable too"

# This is the regression. credit_entries was added by a migration that ran long
# after the grants were applied, and inherited nothing. A check that only looks
# at tables existing at grant time would have passed while production broke.
PGPASSWORD="$APP_PASS" psql -h "$PGHOST" -p "$PGPORT" -U "$APP_ROLE" -d "$DB" \
  -v ON_ERROR_STOP=1 -qtAX -c \
  "CREATE TABLE public.future_migration_table (id bigserial PRIMARY KEY, note text);" >/dev/null

if as_super -d "$DB" -c "
     SELECT has_table_privilege('$BACKUP_ROLE', 'public.future_migration_table', 'SELECT');" \
     | grep -q '^t$'; then
  pass "default privileges cover tables from future migrations"
else
  fail "a new table is unreadable — ALTER DEFAULT PRIVILEGES FOR ROLE is missing or wrong"
  failures=$((failures + 1))
fi

# pg_dump reads sequence values to emit setval on restore, so a sequence the
# backup role cannot read fails the dump just as a table does.
if as_super -d "$DB" -c "
     SELECT has_sequence_privilege('$BACKUP_ROLE', 'public.future_migration_table_id_seq', 'SELECT');" \
     | grep -q '^t$'; then
  pass "default privileges cover sequences from future migrations"
else
  fail "a new sequence is unreadable — pg_dump will fail on restore metadata"
  failures=$((failures + 1))
fi

bold "pg_dump succeeds as the backup role"

DUMP="$(mktemp -t lei-grant-check-XXXXXX.dump)"
trap 'rm -f "$DUMP"; cleanup' EXIT

if PGPASSWORD="$BACKUP_PASS" pg_dump --format=custom --no-owner --no-acl \
     -h "$PGHOST" -p "$PGPORT" -U "$BACKUP_ROLE" -d "$DB" \
     --file="$DUMP" 2>/tmp/lei-grant-check-err.txt; then
  pass "dump completed"
else
  fail "pg_dump failed as $BACKUP_ROLE"
  sed 's/^/    /' /tmp/lei-grant-check-err.txt
  failures=$((failures + 1))
fi

bold "The dump contains every table, not a hardcoded subset"

# backup.yml checks a fixed list of table names, which is why it would not have
# caught credit_entries either. Derive the expectation from the schema instead.
if [ -s "$DUMP" ]; then
  pg_restore --list "$DUMP" > /tmp/lei-grant-check-toc.txt

  missing=""
  while read -r t; do
    [ -z "$t" ] && continue
    grep -q "TABLE DATA public $t" /tmp/lei-grant-check-toc.txt || missing="$missing $t"
  done < <(as_super -d "$DB" -c \
      "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;")

  if [ -z "$missing" ]; then
    pass "all tables present in the dump"
  else
    fail "missing from dump:$missing"
    failures=$((failures + 1))
  fi
fi

echo
if [ "$failures" -eq 0 ]; then
  bold "=== backup grants verified ==="
  echo "The backup role can dump everything the application creates, including"
  echo "tables added by migrations that run after the grants were applied."
  exit 0
fi

bold "=== $failures check(s) failed ==="
echo "See 'Backup database user' in apps/lowendinsight_get/docs/OPERATIONS.md."
exit 1
