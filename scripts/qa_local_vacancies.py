"""Exercise student vacancy submissions with the checked-in authoring RPCs."""
import re
import sys

from qa_local_schema_suite import ROOT, run_suite

MIGRATIONS = ROOT / "supabase/migrations"


def table(source, name):
    pattern = rf"^create table if not exists public\.{name} \(.*?^\);"
    return re.search(pattern, source, re.M | re.S).group()


def function(source, name):
    pattern = rf"^create or replace function (?:public|private)\.{name}\(.*?^\$\$;"
    return re.search(pattern, source, re.M | re.S).group()


def setup(schema, students):
    owner, peer = students
    def read(name):
        return (MIGRATIONS / name).read_text("utf-8")

    rbac = read("20260721202054_admin_rbac_and_audit.sql")
    foundation = read("20260729133000_stage14_managed_content_foundation.sql")
    vacancies = read("20260729151000_stage17_vacancies_domain.sql")
    transitions = read("20260729152060_stage18_reviews_points_p1_round3.sql")
    authors = read("20260729152070_stage18_reviews_points_p1_round4.sql")
    news = read("20260722110804_news_posts_and_admin_rpc.sql")
    board = read("20260731000318_stage14_1_4_vacancy_assets_role_in_get_my.sql")
    definitions = [
        "create table users (id uuid primary key, is_active boolean default true);",
        "create table groups (id uuid primary key);",
        "create table student_enrollments (user_id uuid, group_id uuid references groups, status text, ended_at timestamptz);",
        table(rbac, "admin_audit_log"), table(foundation, "content_audit_log"),
        function(rbac, "admin_sanitize_audit_metadata"), function(rbac, "admin_write_audit"),
        function(foundation, "content_write_domain_audit"),
        *(table(vacancies, name) for name in ("vacancies", "vacancy_versions",
          "vacancy_audience_groups", "vacancy_audience_users", "vacancy_assets",
          "vacancy_reports", "vacancy_moderation_actions")),
        *(function(vacancies, name) for name in ("vacancy_assert_contacts", "vacancy_assert_patch",
          "vacancy_to_admin_json", "vacancy_snapshot_version", "vacancy_record_action", "submit_vacancy")),
        function(transitions, "vacancy_assert_transition"),
        *(function(authors, name) for name in ("get_my_vacancy_submissions",
                                               "update_my_vacancy_draft", "resubmit_my_vacancy")),
        function(news, "current_user_active_group_ids"),
        *(function(vacancies, name) for name in ("vacancy_audience_matches", "vacancy_deliverable_to_user",
                                                 "get_vacancy_contacts", "report_vacancy")),
        function(board, "get_my_vacancies"),
    ]
    statements = "\n".join(definitions).replace("public.", schema + ".").replace("private.", schema + ".")
    # Set up the moderator's disposition of one synthetic application. Student actions
    # use the real production RPCs above, and the peer cannot see the owner's rows.
    statements += f"""
        insert into users (id) values ('{owner}'), ('{peer}');
        insert into groups values (gen_random_uuid()), (gen_random_uuid());
        insert into student_enrollments values
          ('{owner}', (select id from groups order by id asc limit 1), 'active', null),
          ('{peer}', (select id from groups order by id desc limit 1), 'active', null);
        alter table vacancy_assets add column working_draft_id uuid, add column role text default 'attachment';
        insert into vacancies(title, company_name, summary, status, priority, published_at, contacts,
                              description, audience_mode, origin, starts_at, expires_at) values
          ('Bridge inspector', 'North Quay', 'Summer placement', 'published', 20, now(),
           '{{"email":"hiring@example.invalid","person":"QA Recruiter"}}', 'Inspect bridge decks', 'all', 'admin', null, null),
          ('Lab assistant', 'Materials Lab', 'Lab sessions', 'published', 20, now() - interval '1 day',
           '{{}}', 'Test concrete samples', 'all', 'admin', null, null),
          ('Sample role', 'Training company', 'Practice listing', 'published', 1, now(),
           '{{}}', 'Sample vacancy for orientation', 'all', 'demo', null, null),
          ('Survey crew', 'Owner group', 'Survey the site', 'published', 5, now(),
           '{{}}', 'Site work', 'groups', 'admin', null, null),
          ('Hydrology crew', 'Peer group', 'Measure the river', 'published', 5, now(),
           '{{}}', 'Field work', 'groups', 'admin', null, null),
          ('Future opening', '', 'Not yet open', 'published', 99, now(), '{{}}', '', 'all', 'admin', now() + interval '1 day', null),
          ('Closed opening', '', 'Past deadline', 'published', 99, now() - interval '1 day', '{{}}', '', 'all', 'admin', null, now() - interval '1 hour');
        insert into vacancy_audience_groups (vacancy_id,group_id)
          select v.id, se.group_id from vacancies v join student_enrollments se
            on (v.title='Survey crew' and se.user_id='{owner}')
            or (v.title='Hydrology crew' and se.user_id='{peer}');
        insert into vacancies(title,summary,status,origin,submitted_by,rejection_reason)
          values ('Concurrent draft','Original duties','draft','user_submission','{owner}','Clarify duties');
        insert into vacancies(title, summary, status, origin, submitted_by, rejection_reason,
          created_at, location, salary_text, external_url, contacts) values
          ('Clear optional details', 'Review revised details', 'draft', 'user_submission', '{owner}',
            'Update contact details', now() - interval '7 days', 'Office', '30000',
            'https://example.org/old', '{{"email":"old@example.org","phone":"+15551234567","telegram":"@otherdesk"}}'),
          ('Cancel edits', 'Original summary', 'draft', 'user_submission', '{owner}',
            'Provide project dates', now() - interval '7 days', null, null, null, '{{}}'),
          ('Rejected placement', 'Old programme', 'rejected', 'user_submission', '{owner}',
            'Programme closed', now() - interval '7 days', null, null, null, '{{}}'),
          ('Peer placement', 'Other student', 'approved', 'user_submission', '{peer}',
            null, now() - interval '7 days', null, null, null, '{{}}');
        update vacancies set employment_type='internship', work_format='hybrid'
          where title='Clear optional details';
        create function fixture_clarify_requirements() returns void language sql security definer
        set search_path = '' as $$
          update {schema}.vacancies set status='draft', rejection_reason='Clarify hours',
            row_version=row_version+1 where title='Blueprint placement' and submitted_by=auth.uid()
            and status='submitted' and auth.uid()='{owner}';
        $$;
        create function fixture_own_reports() returns jsonb language sql stable security definer
        set search_path = '' as $$
          select coalesce(jsonb_agg(jsonb_build_object('title', v.title, 'reason', r.reason_code,
                    'reporter', r.reporter_user_id)), '[]'::jsonb)
          from {schema}.vacancy_reports r join {schema}.vacancies v on v.id=r.vacancy_id
          where r.reporter_user_id=auth.uid()
        $$;
        revoke execute on all functions in schema {schema} from public;
        grant execute on function submit_vacancy(jsonb), get_my_vacancy_submissions(integer),
          update_my_vacancy_draft(uuid,jsonb,integer), resubmit_my_vacancy(uuid,integer),
          fixture_clarify_requirements(), get_my_vacancies(), get_vacancy_contacts(uuid),
          report_vacancy(uuid,text,text), fixture_own_reports() to authenticated;
        """
    return statements, {}


if __name__ == "__main__":
    sys.exit(run_suite("vacancy", setup, "integration_test/ordinary_vacancies_local_test.dart",
                       "STUDENT_VACANCY_LOCAL", student_count=2))
