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
    definitions = [
        "create table users (id uuid primary key, is_active boolean default true);",
        "create table groups (id uuid primary key);",
        "create table student_enrollments (user_id uuid, status text, ended_at timestamptz);",
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
    ]
    statements = "\n".join(definitions).replace("public.", schema + ".").replace("private.", schema + ".")
    # Set up the moderator's disposition of one synthetic application. Student actions
    # use the real production RPCs above, and the peer cannot see the owner's rows.
    statements += f"""
        insert into users (id) values ('{owner}'), ('{peer}');
        insert into student_enrollments values ('{owner}', 'active', null), ('{peer}', 'active', null);
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
        revoke execute on all functions in schema {schema} from public;
        grant execute on function submit_vacancy(jsonb), get_my_vacancy_submissions(integer),
          update_my_vacancy_draft(uuid,jsonb,integer), resubmit_my_vacancy(uuid,integer),
          fixture_clarify_requirements() to authenticated;
        """
    return statements, {}


if __name__ == "__main__":
    sys.exit(run_suite("vacancy", setup, "integration_test/ordinary_vacancies_local_test.dart",
                       "STUDENT_VACANCY_LOCAL", student_count=2))
