-- Isolated test fixture extension for published home-promo edit coordination.
create table public.content_items (
 id uuid primary key, template_key text not null, status text not null,
 row_version integer not null, payload jsonb not null
);
create table public.content_assets (
 id uuid primary key, content_item_id uuid not null,
 storage_bucket text not null, storage_path text not null
);
create table public.content_item_working_drafts (
 id uuid primary key default gen_random_uuid(), content_item_id uuid unique not null,
 base_canonical_row_version integer not null, payload jsonb not null,
 draft_asset_ids uuid[] not null default '{}', row_version integer not null,
 created_by uuid not null
);
create function public.admin_begin_content_edit(p_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_uid uuid; v_item public.content_items%rowtype; v_draft public.content_item_working_drafts%rowtype;
begin
 v_uid:=private.require_admin_permission('content.write');
 select * into v_item from public.content_items where id=p_id for update;
 select * into v_draft from public.content_item_working_drafts where content_item_id=p_id;
 if not found then
  insert into public.content_item_working_drafts(content_item_id,base_canonical_row_version,payload,row_version,created_by)
  values(p_id,v_item.row_version,v_item.payload,1,v_uid) returning * into v_draft;
 end if;
 return jsonb_build_object('working_draft',jsonb_build_object('id',v_draft.id,
   'row_version',v_draft.row_version,'base_canonical_row_version',v_draft.base_canonical_row_version,
   'payload',v_draft.payload,'draft_asset_ids',to_jsonb(v_draft.draft_asset_ids)));
end $$;
