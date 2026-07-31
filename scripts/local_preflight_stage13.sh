#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/.local/share/supabase:${HOME}/.deno/bin:${PATH}"
cd "$ROOT"

PROJECT_ID="student_platform"
DB_CONTAINER="supabase_db_${PROJECT_ID}"
STASH=""
TMPDIR_PREFLIGHT="$(mktemp -d "${TMPDIR:-/tmp}/stage13_preflight.XXXXXX")"

cleanup() {
  local ec=$?
  if [[ -n "${STASH}" && -d "${STASH}" ]]; then
    shopt -s nullglob
    for f in "${STASH}"/*.sql; do
      mv "$f" supabase/migrations/
    done
    rmdir "${STASH}" 2>/dev/null || true
  fi
  rm -rf "${TMPDIR_PREFLIGHT}"
  return "$ec"
}
trap cleanup EXIT

run_sql_file() {
  local file="$1"
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$file"
}

run_sql() {
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

echo "[1/9] Pin storage-version in ignored .temp only"
mkdir -p supabase/.temp
printf 'v1.28.0\n' > supabase/.temp/storage-version
rm -rf supabase/.temp/storage-migration || true

echo "[2/9] Park historical migrations (incomplete empty-reset chain)"
STASH="supabase/.migrations_stash_$$"
mkdir -p "$STASH"
shopt -s nullglob
for f in supabase/migrations/*.sql; do
  mv "$f" "$STASH/"
done

echo "[3/9] Start clean local Supabase for this project"
supabase stop --project-id "$PROJECT_ID" --no-backup >/dev/null 2>&1 || true
supabase start
if ! docker ps --format '{{.Names}}' | rg -x "$DB_CONTAINER" >/dev/null; then
  echo "Expected container missing: $DB_CONTAINER" >&2
  docker ps --format '{{.Names}}' | rg 'supabase_db_' || true
  exit 1
fi
OTHER="$(docker ps --format '{{.Names}}' | rg '^supabase_db_' | rg -v "^${DB_CONTAINER}$" || true)"
if [[ -n "${OTHER}" ]]; then
  echo "NOTE: other supabase_db containers running (ignored): ${OTHER}"
fi

echo "[4/9] Apply local baseline (LOCAL ONLY, never remote)"
run_sql_file supabase/local/pre_stage13_baseline.sql

echo "[5/9] Apply dependency + pending migrations in order"
for f in \
  20260721202054_admin_rbac_and_audit.sql \
  20260722110804_news_posts_and_admin_rpc.sql \
  20260727183823_admin_news_archive_delete.sql \
  20260727184049_stage13_2_group_space.sql \
  20260727184156_stage13_3_teachers_admin.sql \
  20260727184238_stage13_4_subjects_admin.sql \
  20260727184423_stage13_5_students_groups_terms_admin.sql \
  20260727184457_stage13_6_reviews_moderation.sql \
  20260727184511_stage13_2_admin_group_organizer.sql
do
  echo "  -> $f"
  run_sql_file "$STASH/$f"
done

echo "[6/9] Runtime role-play"
run_sql_file supabase/checks/stage13_local_runtime_roleplay.sql

echo "[7/9] Concurrent topic race (two DB sessions)"
ORG='a2222222-2222-2222-2222-222222222222'
S1='a3333333-3333-3333-3333-333333333333'
S2='a4444444-4444-4444-4444-444444444444'

run_sql <<SQL
create table if not exists public.preflight_race_gate (
  id integer primary key,
  open boolean not null default false
);
insert into public.preflight_race_gate(id, open) values (1, false)
on conflict (id) do update set open = false;
SQL

# Stay as postgres; only JWT claims are needed for auth.uid() inside SECURITY DEFINER RPCs.
run_sql -q -At <<SQL > "${TMPDIR_PREFLIGHT}/race_ids.txt"
create temporary table preflight_race_ids(selection_id uuid, option_id uuid) on commit preserve rows;
do \$\$
declare
  v_selection uuid;
  v_option uuid;
begin
  perform set_config('request.jwt.claim.sub', '${ORG}', true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', '${ORG}', 'role', 'authenticated')::text,
    true
  );
  v_selection := public.create_topic_selection('Concurrent race', '', null, true);
  v_option := public.add_topic_option(v_selection, 'Only seat', 1, 1);
  insert into preflight_race_ids values (v_selection, v_option);
end;
\$\$;
select selection_id::text || ' ' || option_id::text from preflight_race_ids;
SQL
RACE_LINE="$(rg -N '^[0-9a-f-]{36} [0-9a-f-]{36}$' "${TMPDIR_PREFLIGHT}/race_ids.txt" | head -n 1 || true)"
if [[ -z "${RACE_LINE}" ]]; then
  echo "FAIL: race setup did not return ids" >&2
  cat "${TMPDIR_PREFLIGHT}/race_ids.txt" >&2 || true
  exit 1
fi
SELECTION_ID="$(echo "${RACE_LINE}" | awk '{print $1}')"
OPTION_ID="$(echo "${RACE_LINE}" | awk '{print $2}')"
echo "  selection=${SELECTION_ID} option=${OPTION_ID}"

write_worker() {
  local uid="$1"
  local path="$2"
  cat > "$path" <<SQL
do \$\$
begin
  perform set_config('request.jwt.claim.sub', '${uid}', true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', '${uid}', 'role', 'authenticated')::text,
    true
  );
  while not coalesce((select open from public.preflight_race_gate where id = 1), false) loop
    perform pg_sleep(0.02);
  end loop;
  perform public.pick_topic('${SELECTION_ID}'::uuid, '${OPTION_ID}'::uuid);
end;
\$\$;
SQL
}

write_worker "$S1" "${TMPDIR_PREFLIGHT}/race_s1.sql"
write_worker "$S2" "${TMPDIR_PREFLIGHT}/race_s2.sql"

(
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "${TMPDIR_PREFLIGHT}/race_s1.sql" \
    > "${TMPDIR_PREFLIGHT}/race_s1.txt" 2>&1
  echo $? > "${TMPDIR_PREFLIGHT}/race_s1.ec"
) &
PID1=$!
(
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "${TMPDIR_PREFLIGHT}/race_s2.sql" \
    > "${TMPDIR_PREFLIGHT}/race_s2.txt" 2>&1
  echo $? > "${TMPDIR_PREFLIGHT}/race_s2.ec"
) &
PID2=$!

sleep 0.5
run_sql -c "update public.preflight_race_gate set open = true where id = 1;"
wait "$PID1" "$PID2" || true

EC1="$(cat "${TMPDIR_PREFLIGHT}/race_s1.ec" 2>/dev/null || echo 1)"
EC2="$(cat "${TMPDIR_PREFLIGHT}/race_s2.ec" 2>/dev/null || echo 1)"
PICKS="$(run_sql -At -c "select count(*) from public.group_topic_picks where option_id = '${OPTION_ID}'::uuid;")"
echo "  race exits s1=${EC1} s2=${EC2} picks=${PICKS}"
if [[ "${PICKS}" != "1" ]]; then
  echo "FAIL: expected exactly one concurrent pick" >&2
  cat "${TMPDIR_PREFLIGHT}/race_s1.txt" >&2 || true
  cat "${TMPDIR_PREFLIGHT}/race_s2.txt" >&2 || true
  exit 1
fi
if [[ "${EC1}" == "0" && "${EC2}" == "0" ]]; then
  echo "FAIL: both workers succeeded under capacity=1" >&2
  exit 1
fi
if [[ "${EC1}" != "0" && "${EC2}" != "0" ]]; then
  echo "FAIL: both workers failed" >&2
  cat "${TMPDIR_PREFLIGHT}/race_s1.txt" >&2 || true
  cat "${TMPDIR_PREFLIGHT}/race_s2.txt" >&2 || true
  exit 1
fi
echo "  concurrent race PASS"

echo "[8/9] Assertive security checks"
for f in supabase/checks/stage13_*_security_review.sql; do
  echo "  check $(basename "$f")"
  run_sql_file "$f"
done

echo "[9/9] Repo scans"
HITS="$(rg -n "SERVICE_ROLE|serviceRole|createClient\\(.*service_role" admin_console/lib -g '*.dart' || true)"
if [[ -n "${HITS}" ]]; then
  echo "${HITS}"
  echo "FAIL: service_role client usage in admin_console/lib" >&2
  exit 1
fi
echo "admin_console/lib: no service_role client usage"

echo "PREFLIGHT_OK"
