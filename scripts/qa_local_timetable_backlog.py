"""Exercise imported teaching schedules using archived RPC bodies in a local test schema."""
import sys
from uuid import uuid4
from qa_local_schema_suite import ROOT, run_suite


def setup(schema, accounts):
    # An existing schema-only snapshot supplies the original get_my_lessons and f_norm_title.
    # Only these two function bodies are needed. No data from the snapshot is loaded.
    fixture = (ROOT / "scripts/qa_schedule_hundred_fixture.sql").read_text("utf-8")
    source = (ROOT / "supabase/stage2_3_schedule_subject_resolver.sql").read_text("utf-8")
    functions = source[source.index("create or replace function"):source.index("revoke all on function")]
    group_a, group_b, subject_a, subject_b, off_a, off_b, off_peer, term = [str(uuid4()) for _ in range(8)]
    values = dict(student=accounts[0], peer=accounts[1], a=group_a, b=group_b,
                  sub1=subject_a, sub2=subject_b, off1=off_a, off2=off_b, off3=off_peer, term=term)
    values.update(staff=accounts[2], other_student=accounts[3], plan=str(uuid4()))
    definitions, rows = fixture.split("-- Schedule cases", 1)
    sql = (definitions + functions + rows).replace('"public".',schema + ".").replace("public.",schema + ".")
    sql = sql.replace("TO 'public'", "TO '" + schema + "'").replace("to 'public'", "to '" + schema + "'")
    source = (ROOT / "supabase/migrations/20260825102603_academic_ingestion_identity_foundation.sql").read_text("utf-8")
    i = source.index("create or replace function public.admin_assign_group_curriculum_plan(")
    sql += source[i:source.index("$$;",source.index("as $$",i))+3].replace("public.",schema+".").replace("private.",schema+".")
    sql += "revoke all on function admin_assign_group_curriculum_plan(uuid,uuid,uuid) from public,anon; grant execute on function admin_assign_group_curriculum_plan(uuid,uuid,uuid) to authenticated;"
    migrations = ROOT / "supabase/migrations"
    source = (migrations / "20260721095738_teacher_difficulty_ratings.sql").read_text("utf-8")
    rating = source[source.index("create table if not exists public.teacher_difficulty_targets"):]
    rating += (migrations / "20260721150000_teacher_about_text.sql").read_text("utf-8")
    sql += rating.replace("public.",schema+".").replace("private.",schema+".").replace("pg_catalog, public, private","pg_catalog, "+schema).replace("pg_catalog, public","pg_catalog, "+schema)
    sql += "insert into teacher_difficulty_targets(display_name,normalized_name) values('Replacement teacher','replacement teacher');"
    subgroup = (migrations / '20261125203603_student_schedule_subgroup_audiences.sql').read_text('utf-8-sig')
    sql = sql.replace('private.schedule_subgroup_', schema+'.schedule_subgroup_').replace(
        'private.tag_schedule_subgroup_lesson',schema+'.tag_schedule_subgroup_lesson')
    sql = sql.replace('private.set_schedule_enrollment_subgroup',schema+'.set_schedule_enrollment_subgroup')
    sql += subgroup.replace('public.', schema+'.').replace('private.', schema+'.')
    for key,val in values.items():
        sql = sql.replace(":" + key + ":",val)
    return sql, {key: val for key, val in values.items() if key not in ("student","peer")}


if __name__ == "__main__":
    sys.exit(run_suite("timetable", setup, "integration_test/ordinary_timetable_backlog_test.dart",
                       "STUDENT_TIMETABLE_LOCAL", student_count=4,
                       required_markers=("E2E-052 PASS two active academic groups without a subgroup roster",
                                         "E2E-059 changed enrollment")))
