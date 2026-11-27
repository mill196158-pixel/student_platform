
-- Synthetic subjects for the route comparison in the local QA schema.
update subject_catalog set canonical_name = case canonical_name
  when 'Сопромат' then 'Надежность систем водоснабжения и водоотведения'
  else 'Моделирование систем водоснабжения и водоотведения'
end where canonical_name in ('Сопромат', 'Курсовой проект и практика');
update subject_offerings so set display_name = sc.canonical_name
from subject_catalog sc where so.subject_id = sc.id;
update teams t set name = so.display_name, group_id = so.group_id,
  subject_id = so.subject_id, semester_number = so.semester_number,
  academic_year_id = ':year:', academic_term_id = ':term:'
from subject_offerings so where t.subject_offering_id = so.id;

create function get_my_teams() returns setof teams
language sql stable set search_path from current as $$
  select t.* from teams t
  join rpc_get_my_subjects_v2() v on v.team_id = t.id
$$;
revoke execute on function get_my_teams() from public, anon;
grant execute on function get_my_teams() to authenticated;

update messages set body = 'История Надежности водоснабжения',
  content = 'История Надежности водоснабжения'
where chat_id = ':chat_project:';
update messages set body = 'История Моделирования водоснабжения',
  content = 'История Моделирования водоснабжения'
where chat_id = ':chat_control:';

insert into messages (id, chat_id, author_id, body, content)
select link_id, source_chat, ':student:', message, message
from (values
  (':link_to_project:'::uuid, ':chat_control:'::uuid,
    'Обсуждение надежности' || chr(10) || 'studentplatform://chat/:chat_project:'),
  (':link_to_control:'::uuid, ':chat_project:'::uuid,
    'Обсуждение моделирования' || chr(10) || 'studentplatform://chat/:chat_control:')
) as links(link_id, source_chat, message);

-- Required tables for the exact production content_resolve_chat_cta contract.
alter table users add column is_active boolean not null default true;
create table chat_members(chat_id uuid references chats, user_id uuid,
  primary key (chat_id, user_id));
create view chat_academic_archives as select chat_id from fixture_archived_chat;
create function get_my_group_space() returns jsonb
language sql stable as $$ select null::jsonb $$;
revoke execute on function get_my_group_space() from public, anon;
