begin;

-- NEACEA MASTER MEMORY V0.1
-- This schema is intentionally private and has no seeded personal data.
create schema master_memory;

create type master_memory.memory_type as enum (
  'FACT',
  'PREFERENCE',
  'DECISION',
  'EVENT',
  'PROJECT_STATE',
  'PROCEDURE',
  'GOAL',
  'NOTE'
);

create type master_memory.memory_status as enum (
  'CURRENT',
  'SUPERSEDED',
  'ARCHIVED',
  'TO_VERIFY'
);

create type master_memory.sensitivity_level as enum (
  'PUBLIC',
  'PRIVATE',
  'CONFIDENTIAL',
  'HIGHLY_SENSITIVE'
);

create type master_memory.source_type as enum (
  'CONVERSATION',
  'DOCUMENT',
  'MANUAL_ENTRY',
  'SYSTEM_APPLICATION',
  'IMPORT'
);

create type master_memory.acquisition_mode as enum (
  'AUTOMATIC',
  'CONFIRM',
  'NEVER_AUTO'
);

create type master_memory.presence_state as enum (
  'PRESENT_IN_MASTER',
  'CONVERSATION_ONLY',
  'DISMISSED'
);

create table master_memory.memory_sources (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  source_type master_memory.source_type not null,
  source_label text not null check (char_length(btrim(source_label)) > 0),
  source_reference text,
  source_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table master_memory.memory_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  current_version_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table master_memory.memory_versions (
  id uuid primary key default gen_random_uuid(),
  memory_id uuid not null references master_memory.memory_items(id) on delete restrict,
  version integer not null check (version > 0),
  supersedes_version_id uuid references master_memory.memory_versions(id) on delete restrict,
  category text not null check (char_length(btrim(category)) > 0),
  memory_type master_memory.memory_type not null,
  title text not null check (char_length(btrim(title)) > 0),
  content text not null,
  status master_memory.memory_status not null default 'CURRENT'
    check (status <> 'SUPERSEDED'),
  sensitivity master_memory.sensitivity_level not null default 'PRIVATE',
  reliability smallint not null default 50 check (reliability between 0 and 100),
  source_id uuid not null references master_memory.memory_sources(id) on delete restrict,
  valid_from timestamptz,
  valid_to timestamptz,
  acquisition_mode master_memory.acquisition_mode not null default 'CONFIRM',
  metadata jsonb not null default '{}'::jsonb,
  search_vector tsvector generated always as (
    to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(content, ''))
  ) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint memory_versions_validity_window_check
    check (valid_to is null or valid_from is null or valid_to >= valid_from),
  constraint memory_versions_memory_id_version_key unique (memory_id, version)
);

alter table master_memory.memory_items
  add constraint memory_items_current_version_id_fkey
  foreign key (current_version_id)
  references master_memory.memory_versions(id)
  on delete restrict
  deferrable initially deferred;

create table master_memory.memory_intake_records (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  source_id uuid not null references master_memory.memory_sources(id) on delete restrict,
  memory_id uuid references master_memory.memory_items(id) on delete restrict,
  supersedes_intake_record_id uuid references master_memory.memory_intake_records(id) on delete restrict,
  content_fingerprint text not null check (content_fingerprint ~ '^[0-9a-f]{64}$'),
  acquisition_mode master_memory.acquisition_mode not null,
  presence_state master_memory.presence_state not null,
  created_at timestamptz not null default now(),
  constraint memory_intake_records_presence_check check (
    (presence_state = 'PRESENT_IN_MASTER' and memory_id is not null)
    or (presence_state in ('CONVERSATION_ONLY', 'DISMISSED') and memory_id is null)
  )
);

create index memory_sources_owner_id_idx
  on master_memory.memory_sources(owner_id);

create index memory_versions_memory_id_idx
  on master_memory.memory_versions(memory_id, version desc);

create index memory_versions_source_id_idx
  on master_memory.memory_versions(source_id);

create index memory_versions_status_idx
  on master_memory.memory_versions(status);

create index memory_versions_validity_idx
  on master_memory.memory_versions(valid_from, valid_to);

create index memory_versions_search_vector_idx
  on master_memory.memory_versions using gin(search_vector);

create index memory_intake_records_owner_fingerprint_idx
  on master_memory.memory_intake_records(owner_id, content_fingerprint);

create index memory_intake_records_memory_id_idx
  on master_memory.memory_intake_records(memory_id)
  where memory_id is not null;

-- Versions, source records, and intake records are append-only. A replacement is a new row.
create function master_memory.prevent_immutable_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  raise exception 'master memory history is append-only; create a successor record instead';
end;
$$;

create trigger memory_sources_are_immutable
  before update or delete on master_memory.memory_sources
  for each row execute function master_memory.prevent_immutable_mutation();

create trigger memory_versions_are_immutable
  before update or delete on master_memory.memory_versions
  for each row execute function master_memory.prevent_immutable_mutation();

create trigger memory_intake_records_are_immutable
  before update or delete on master_memory.memory_intake_records
  for each row execute function master_memory.prevent_immutable_mutation();

create trigger memory_items_cannot_be_deleted
  before delete on master_memory.memory_items
  for each row execute function master_memory.prevent_immutable_mutation();

-- The view derives SUPERSEDED from the current pointer instead of mutating old versions.
create view master_memory.memory_version_status
with (security_invoker = true)
as
select
  mi.owner_id,
  mi.current_version_id,
  mv.id as version_id,
  mv.memory_id,
  mv.version,
  mv.supersedes_version_id,
  mv.category,
  mv.memory_type,
  mv.title,
  mv.content,
  case
    when mi.current_version_id is distinct from mv.id then 'SUPERSEDED'::master_memory.memory_status
    else mv.status
  end as effective_status,
  mv.sensitivity,
  mv.reliability,
  mv.source_id,
  mv.valid_from,
  mv.valid_to,
  mv.acquisition_mode,
  mv.metadata,
  mv.search_vector,
  mv.created_at,
  mv.updated_at
from master_memory.memory_items mi
join master_memory.memory_versions mv on mv.memory_id = mi.id;

-- Security-definer functions are private, validate the caller, and are the only
-- supported write path for immutable memory versions.
create function master_memory.create_memory_source(
  p_source_type master_memory.source_type,
  p_source_label text,
  p_source_reference text default null,
  p_source_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner_id uuid := auth.uid();
  v_source_id uuid;
begin
  if v_owner_id is null then
    raise exception 'an authenticated owner is required';
  end if;

  insert into master_memory.memory_sources (
    owner_id, source_type, source_label, source_reference, source_metadata
  )
  values (
    v_owner_id, p_source_type, p_source_label, p_source_reference,
    coalesce(p_source_metadata, '{}'::jsonb)
  )
  returning id into v_source_id;

  return v_source_id;
end;
$$;

create function master_memory.create_memory(
  p_category text,
  p_memory_type master_memory.memory_type,
  p_title text,
  p_content text,
  p_source_id uuid,
  p_status master_memory.memory_status default 'CURRENT',
  p_sensitivity master_memory.sensitivity_level default 'PRIVATE',
  p_reliability smallint default 50,
  p_valid_from timestamptz default null,
  p_valid_to timestamptz default null,
  p_acquisition_mode master_memory.acquisition_mode default 'CONFIRM',
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner_id uuid := auth.uid();
  v_memory_id uuid;
  v_version_id uuid;
begin
  if v_owner_id is null then
    raise exception 'an authenticated owner is required';
  end if;

  if p_status = 'SUPERSEDED' then
    raise exception 'a new memory cannot be created as SUPERSEDED';
  end if;

  if not exists (
    select 1
    from master_memory.memory_sources
    where id = p_source_id and owner_id = v_owner_id
  ) then
    raise exception 'source does not belong to the authenticated owner';
  end if;

  insert into master_memory.memory_items (owner_id)
  values (v_owner_id)
  returning id into v_memory_id;

  insert into master_memory.memory_versions (
    memory_id, version, category, memory_type, title, content, status,
    sensitivity, reliability, source_id, valid_from, valid_to,
    acquisition_mode, metadata
  )
  values (
    v_memory_id, 1, p_category, p_memory_type, p_title, p_content, p_status,
    p_sensitivity, p_reliability, p_source_id, p_valid_from, p_valid_to,
    p_acquisition_mode, coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_version_id;

  update master_memory.memory_items
  set current_version_id = v_version_id,
      updated_at = now()
  where id = v_memory_id;

  return v_memory_id;
end;
$$;

create function master_memory.create_memory_version(
  p_memory_id uuid,
  p_category text,
  p_memory_type master_memory.memory_type,
  p_title text,
  p_content text,
  p_source_id uuid,
  p_status master_memory.memory_status default 'CURRENT',
  p_sensitivity master_memory.sensitivity_level default 'PRIVATE',
  p_reliability smallint default 50,
  p_valid_from timestamptz default null,
  p_valid_to timestamptz default null,
  p_acquisition_mode master_memory.acquisition_mode default 'CONFIRM',
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner_id uuid := auth.uid();
  v_previous_version_id uuid;
  v_version_id uuid;
  v_next_version integer;
begin
  if v_owner_id is null then
    raise exception 'an authenticated owner is required';
  end if;

  if p_status = 'SUPERSEDED' then
    raise exception 'a successor version cannot be created as SUPERSEDED';
  end if;

  select current_version_id
  into v_previous_version_id
  from master_memory.memory_items
  where id = p_memory_id and owner_id = v_owner_id
  for update;

  if not found or v_previous_version_id is null then
    raise exception 'memory does not belong to the authenticated owner';
  end if;

  if not exists (
    select 1
    from master_memory.memory_sources
    where id = p_source_id and owner_id = v_owner_id
  ) then
    raise exception 'source does not belong to the authenticated owner';
  end if;

  select coalesce(max(version), 0) + 1
  into v_next_version
  from master_memory.memory_versions
  where memory_id = p_memory_id;

  insert into master_memory.memory_versions (
    memory_id, version, supersedes_version_id, category, memory_type, title,
    content, status, sensitivity, reliability, source_id, valid_from, valid_to,
    acquisition_mode, metadata
  )
  values (
    p_memory_id, v_next_version, v_previous_version_id, p_category,
    p_memory_type, p_title, p_content, p_status, p_sensitivity, p_reliability,
    p_source_id, p_valid_from, p_valid_to, p_acquisition_mode,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_version_id;

  update master_memory.memory_items
  set current_version_id = v_version_id,
      updated_at = now()
  where id = p_memory_id;

  return v_version_id;
end;
$$;

create function master_memory.search_memory(
  p_query text default null,
  p_include_history boolean default false,
  p_include_highly_sensitive boolean default false
)
returns table (
  memory_id uuid,
  version_id uuid,
  version integer,
  category text,
  memory_type master_memory.memory_type,
  title text,
  content text,
  status master_memory.memory_status,
  sensitivity master_memory.sensitivity_level,
  reliability smallint,
  source_id uuid,
  valid_from timestamptz,
  valid_to timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner_id uuid := auth.uid();
  v_query text := nullif(btrim(p_query), '');
begin
  if v_owner_id is null then
    raise exception 'an authenticated owner is required';
  end if;

  return query
  select
    mvs.memory_id,
    mvs.version_id,
    mvs.version,
    mvs.category,
    mvs.memory_type,
    mvs.title,
    mvs.content,
    mvs.effective_status,
    mvs.sensitivity,
    mvs.reliability,
    mvs.source_id,
    mvs.valid_from,
    mvs.valid_to,
    mvs.updated_at
  from master_memory.memory_version_status mvs
  where mvs.owner_id = v_owner_id
    and (p_include_history or mvs.version_id = mvs.current_version_id)
    and (p_include_highly_sensitive or mvs.sensitivity <> 'HIGHLY_SENSITIVE')
    and (
      v_query is null
      or mvs.search_vector @@ websearch_to_tsquery('simple', v_query)
    )
  order by
    case
      when v_query is null then 0
      else ts_rank(mvs.search_vector, websearch_to_tsquery('simple', v_query))
    end desc,
    mvs.updated_at desc;
end;
$$;

create function master_memory.export_memory_json(
  p_include_highly_sensitive boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner_id uuid := auth.uid();
  v_records jsonb;
begin
  if v_owner_id is null then
    raise exception 'an authenticated owner is required';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'memory_id', mvs.memory_id,
        'version_id', mvs.version_id,
        'version', mvs.version,
        'supersedes_version_id', mvs.supersedes_version_id,
        'category', mvs.category,
        'type', mvs.memory_type,
        'title', mvs.title,
        'content', mvs.content,
        'status', mvs.effective_status,
        'sensitivity', mvs.sensitivity,
        'reliability', mvs.reliability,
        'valid_from', mvs.valid_from,
        'valid_to', mvs.valid_to,
        'acquisition_mode', mvs.acquisition_mode,
        'metadata', mvs.metadata,
        'created_at', mvs.created_at,
        'updated_at', mvs.updated_at,
        'source', jsonb_build_object(
          'id', ms.id,
          'type', ms.source_type,
          'label', ms.source_label,
          'reference', ms.source_reference,
          'metadata', ms.source_metadata,
          'created_at', ms.created_at
        )
      )
      order by mvs.memory_id, mvs.version
    ),
    '[]'::jsonb
  )
  into v_records
  from master_memory.memory_version_status mvs
  join master_memory.memory_sources ms on ms.id = mvs.source_id
  where mvs.owner_id = v_owner_id
    and (p_include_highly_sensitive or mvs.sensitivity <> 'HIGHLY_SENSITIVE');

  return jsonb_build_object(
    'format_version', '0.1',
    'exported_at', now(),
    'records', v_records
  );
end;
$$;

-- Defense in depth: all base tables are private, protected by RLS, and have
-- no direct privileges for API roles. Access goes through the checked RPCs.
alter table master_memory.memory_sources enable row level security;
alter table master_memory.memory_sources force row level security;
alter table master_memory.memory_items enable row level security;
alter table master_memory.memory_items force row level security;
alter table master_memory.memory_versions enable row level security;
alter table master_memory.memory_versions force row level security;
alter table master_memory.memory_intake_records enable row level security;
alter table master_memory.memory_intake_records force row level security;

create policy memory_sources_select_own
  on master_memory.memory_sources
  for select
  to authenticated
  using (owner_id = (select auth.uid()));

create policy memory_items_select_own
  on master_memory.memory_items
  for select
  to authenticated
  using (owner_id = (select auth.uid()));

create policy memory_versions_select_own
  on master_memory.memory_versions
  for select
  to authenticated
  using (
    exists (
      select 1
      from master_memory.memory_items mi
      where mi.id = memory_versions.memory_id
        and mi.owner_id = (select auth.uid())
    )
  );

create policy memory_intake_records_select_own
  on master_memory.memory_intake_records
  for select
  to authenticated
  using (owner_id = (select auth.uid()));

revoke all on schema master_memory from public, anon;
revoke all on all tables in schema master_memory from public, anon, authenticated;
revoke all on all sequences in schema master_memory from public, anon, authenticated;
revoke all on all functions in schema master_memory from public, anon, authenticated;

grant usage on schema master_memory to authenticated;
grant execute on function master_memory.create_memory_source(
  master_memory.source_type, text, text, jsonb
) to authenticated;
grant execute on function master_memory.create_memory(
  text, master_memory.memory_type, text, text, uuid, master_memory.memory_status,
  master_memory.sensitivity_level, smallint, timestamptz, timestamptz,
  master_memory.acquisition_mode, jsonb
) to authenticated;
grant execute on function master_memory.create_memory_version(
  uuid, text, master_memory.memory_type, text, text, uuid,
  master_memory.memory_status, master_memory.sensitivity_level, smallint,
  timestamptz, timestamptz, master_memory.acquisition_mode, jsonb
) to authenticated;
grant execute on function master_memory.search_memory(text, boolean, boolean)
  to authenticated;
grant execute on function master_memory.export_memory_json(boolean)
  to authenticated;

commit;
