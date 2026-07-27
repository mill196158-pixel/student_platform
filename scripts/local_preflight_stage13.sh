#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/.local/share/supabase:${HOME}/.deno/bin:${PATH}"
cd "$ROOT"

echo "[1/8] Ensure storage-version pin"
mkdir -p supabase/.temp
echo "v1.28.0" > supabase/.temp/storage-version
rm -rf supabase/.temp/storage-migration || true

echo "[2/8] Park historical migrations (incomplete chain)"
STASH="supabase/.migrations_stash_$$"
mkdir -p "$STASH"
shopt -s nullglob
for f in supabase/migrations/*.sql; do
  mv "$f" "$STASH/"
done

cleanup() {
  shopt -s nullglob
  for f in "$STASH"/*.sql; do
    mv "$f" supabase/migrations/
  done
  rmdir "$STASH" 2>/dev/null || true
}
trap cleanup EXIT

DB_CONTAINER="$(docker ps --format '{{.Names}}' | rg '^supabase_db_' | head -1)"
if [[ -z "${DB_CONTAINER}" ]]; then
  echo "No supabase_db container" >&2
  exit 1
fi

run_sql_file() {
  local file="$1"
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$file"
}

echo "[3/8] Start clean local Supabase"
supabase stop --no-backup >/dev/null 2>&1 || true
# keep migrations parked during start
supabase start
DB_CONTAINER="$(docker ps --format '{{.Names}}' | rg '^supabase_db_' | head -1)"

echo "[4/8] Apply local baseline (live-shaped core)"
run_sql_file supabase/local/pre_stage13_baseline.sql

echo "[5/8] Apply dependency + pending migrations in order"
for f in \
  20260721202054_admin_rbac_and_audit.sql \
  20260722110804_news_posts_and_admin_rpc.sql \
  20260722121908_admin_news_archive_delete.sql \
  20260727140000_stage13_2_group_space.sql \
  20260727150000_stage13_3_teachers_admin.sql \
  20260727160000_stage13_4_subjects_admin.sql \
  20260727170000_stage13_5_students_groups_terms_admin.sql \
  20260727180000_stage13_6_reviews_moderation.sql
do
  echo "  -> $f"
  run_sql_file "$STASH/$f"
done

echo "[6/8] Runtime role-play"
run_sql_file supabase/checks/stage13_local_runtime_roleplay.sql

echo "[7/8] Security checks"
for f in supabase/checks/stage13_*_security_review.sql; do
  echo "  check $(basename "$f")"
  run_sql_file "$f"
done

echo "[8/8] Grants/service_role Web Admin scan (repo)"
# Ignore UI copy that mentions service_role as a forbidden pattern.
HITS="$(rg -n "SERVICE_ROLE|serviceRole|createClient\(.*service_role" admin_console/lib -g '*.dart' || true)"
if [[ -n "${HITS}" ]]; then
  echo "${HITS}"
  echo "FAIL: service_role client usage in admin_console/lib" >&2
  exit 1
fi
echo "admin_console/lib: no service_role client usage"

echo "PREFLIGHT_OK"
