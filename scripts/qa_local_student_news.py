"""Run the native news reader against isolated production feed RPCs."""
import sys

from qa_local_schema_suite import ROOT, run_suite
from qa_local_vacancies import function, table


def setup(schema, students, *, legacy=False):
    migrations = ROOT / "supabase/migrations"
    original = (migrations / "20260722110804_news_posts_and_admin_rpc.sql").read_text("utf-8")
    audience = (migrations / "20260729140000_stage15_2_news_audience_extension.sql").read_text("utf-8")
    definitions = [
        "create table users (id uuid primary key,is_active boolean default true);",
        "create table groups (id uuid primary key);",
        "create table student_enrollments(user_id uuid, group_id uuid, status text, ended_at timestamptz);",
        "create type news_post_status as enum ('draft','published','archived');",
        "create type news_audience_type as enum ('all','group');",
        "create type news_card_variant as enum ('gradientText','imageOnly','imageOverlay','imageWithText');",
        table(original,'news_posts'), table(original,'news_views'),
        table(audience,'news_audience_groups'), table(audience,'news_audience_users'),
        *(function(audience, name) for name in ('news_audience_matches','news_post_deliverable_to_user',
                                               'get_my_published_news','mark_news_seen')),
    ]
    page = next(migrations.glob("*_student_published_news_page.sql")).read_text("utf-8-sig")
    if not legacy:
        definitions.append(function(page, 'get_my_published_news_page'))
    page_grant = "" if legacy else "grant execute on function get_my_published_news_page(integer,jsonb) to authenticated;"
    setup_sql = "\n".join(definitions).replace('public.',schema+'.').replace('private.',schema+'.')
    return setup_sql + f"""
      insert into users values ('{students[0]}',true),('{students[1]}',true);
      insert into student_enrollments values ('{students[0]}',null,'active',null),('{students[1]}',null,'active',null);
      insert into news_posts(title,body,sort_order,status,published_at,variant,image_path) values
       ('Campus','First control paragraph',1,'published',now()-interval '2 days','imageOverlay','{schema}/red'),
       ('Campus','Second control paragraph',2,'published',now()-interval '1 day','imageOverlay','{schema}/blue'),
       ('Missing cover','Readable without a cover',3,'published',now(),'imageOverlay','{schema}/absent');
      insert into news_posts(id,title,body,sort_order,status,published_at)
        select md5('{schema}'||g)::uuid,'Bulletin '||g,'Archive note '||g,
               10,'published',null from generate_series(1,24) g;
      with post as (
        insert into news_posts(title,body,sort_order,status,published_at)
        values('Private bulletin','Other audience',0,'published',now()) returning id)
        insert into news_audience_users(news_post_id,user_id) select id,'{students[1]}' from post;
      insert into news_posts(title,body,sort_order,status,is_hidden,ends_at) values
        ('Expired QA','Expired',0,'published',false,now()-interval '1 day'),
        ('Hidden QA','Hidden',0,'published',true,null),
        ('Draft QA','Draft',0,'draft',false,null);
      create function fixture_publish() returns void language sql security definer set search_path=''
      as $$ update {schema}.news_posts set title='Campus revised',updated_at=now() where sort_order=1;
        insert into {schema}.news_posts(title,body,sort_order,status,published_at)
        values('Latest post','Fresh paragraph',0,'published',now()); $$;
      revoke execute on all functions in schema {schema} from public;
      grant execute on function get_my_published_news(),mark_news_seen(uuid,boolean),fixture_publish()
        to authenticated;
      {page_grant}
    """, {"legacy": legacy}


if __name__ == "__main__":
    legacy = "--legacy" in sys.argv[1:]
    refresh_marker = ("PASS E2E-083 compatibility: refreshed the full archive" if legacy
                      else "PASS E2E-083 ordinary archive read two distinct SQL pages")
    sys.exit(run_suite(
        "news", lambda schema, students: setup(schema, students, legacy=legacy),
        "integration_test/ordinary_student_news_local_test.dart", "STUDENT_NEWS_LOCAL",
        student_count=2, required_markers=(
            "PASS E2E-081 home and archive open the same edited publication",
            refresh_marker, "PASS foreign audience hidden for first account",
        ),
    ))
