-- Synthetic-only additions for the single-file protection tests.
insert into public.chat_files(id,chat_id,uploaded_by,file_name,file_key,file_url,file_type,file_size,uploaded_at,is_deleted) values
  ('cccccccc-3333-4333-8333-333333333333','22222222-2222-4222-8222-222222222222','aaaaaaaa-1111-4111-8111-111111111111','elsewhere.pdf','elsewhere-key','elsewhere','application/pdf',10,now(),false),
  ('cccccccc-4444-4444-8444-444444444444','11111111-1111-4111-8111-111111111111','aaaaaaaa-1111-4111-8111-111111111111','deleted.pdf','deleted-key','deleted','application/pdf',10,now(),true),
  ('cccccccc-5555-4555-8555-555555555555','11111111-1111-4111-8111-111111111111','aaaaaaaa-1111-4111-8111-111111111111','own.pdf','own-key','own','application/pdf',10,now(),false),
  ('cccccccc-6666-4666-8666-666666666666','11111111-1111-4111-8111-111111111111','aaaaaaaa-1111-4111-8111-111111111111','concurrent.pdf','concurrent-key','concurrent','application/pdf',10,now(),false),
  ('cccccccc-7777-4777-8777-777777777777','11111111-1111-4111-8111-111111111111','aaaaaaaa-1111-4111-8111-111111111111','sensitive.pdf','sensitive-key','sensitive','application/pdf',10,now(),false),
  ('cccccccc-8888-4888-8888-888888888888','11111111-1111-4111-8111-111111111111','aaaaaaaa-1111-4111-8111-111111111111','unconfirmed.pdf','unconfirmed-key','unconfirmed','application/pdf',10,now(),false),
  ('cccccccc-bbbb-4bbb-8bbb-bbbbbbbbbbbb','11111111-1111-4111-8111-111111111111','aaaaaaaa-1111-4111-8111-111111111111','proof.pdf','proof-key','proof','application/pdf',10,now(),false),
  ('cccccccc-dddd-4ddd-8ddd-dddddddddddd','11111111-1111-4111-8111-111111111111','aaaaaaaa-1111-4111-8111-111111111111','sensitive-race.pdf','sensitive-race-key','sensitive-race','application/pdf',10,now(),false);
update public.chat_files set is_sensitive=true where id='cccccccc-7777-4777-8777-777777777777';
insert into private.chat_file_objects(file_key,chat_id,uploaded_by,file_id,file_name,file_type,file_size,file_url,confirmed)
select file_key,chat_id,uploaded_by,id,file_name,file_type,file_size,file_url,true from public.chat_files
where id in ('cccccccc-3333-4333-8333-333333333333','cccccccc-4444-4444-8444-444444444444','cccccccc-5555-4555-8555-555555555555','cccccccc-6666-4666-8666-666666666666','cccccccc-7777-4777-8777-777777777777','cccccccc-8888-4888-8888-888888888888','cccccccc-bbbb-4bbb-8bbb-bbbbbbbbbbbb','cccccccc-dddd-4ddd-8ddd-dddddddddddd');
update private.chat_file_objects set confirmed=false where file_key='unconfirmed-key';
