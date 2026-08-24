begin;

-- JOURNAL V0.2: raw journal text is stored once in journal_entries. Structured
-- interpretations live in append-only revisions and never replace the raw text.
create type master_memory.journal_entry_classification as enum (
  'EVENT',
  'DECISION',
  'PAYMENT',
  'IDEA',
  'PROBLEM',
  'IMPRESSION',
  'NEXT_ACTION'
);

create type master_memory.journal_memory_link_type as enum (
  'GENERATED',
  'REFERENCED'
);

create table master_memory.journal_entries (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  occurred_at timestamptz not null,
  original_text text not null check (char_length(btrim(original_text)) > 0),
  source_id uuid not null references master_memory.memory_sources(id) on delete restrict,
  project_reference text,
  current_revision_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table master_memory.journal_entry_revisions (
  id uuid primary key default gen_random_uuid(),
  journal_entry_id uuid not null references master_memory.journal_entries(id) on delete restrict,
  revision integer not null check (revision > 0),
  supersedes_revision_id uuid references master_memory.journal_entry_revisions(id) on delete restrict,
  title text,
  structured_text text,
  structured_data jsonb not null default '{}'::jsonb,
  status master_memory.memory_status not null default 'CURRENT'
    check (status <> 'SUPERSEDED'),
  sensitivity master_memory.sensitivity_level not null default 'PRIVATE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint journal_entry_revisions_entry_revision_key unique (journal_entry_id, revision)
);

alter table master_memory.journal_entries
  add constraint journal_entries_current_revision_id_fkey
  foreign key (current_revision_id)
  references master_memory.journal_entry_revisions(id)
  on delete restrict
  deferrable initially deferred;

create table master_memory.journal_revision_classifications (
  id uuid primary key default gen_random_uuid(),
  journal_entry_revision_id uuid not null references master_memory.journal_entry_revisions(id) on delete restrict,
  classification master_memory.journal_entry_classification not null,
  confidence smallint not null default 50 check (confidence between 0 and 100),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint journal_revision_classifications_revision_classification_key
    unique (journal_entry_revision_id, classification)
);

create table master_memory.journal_memory_links (
  id uuid primary key default gen_random_uuid(),
  journal_entry_id uuid not null references master_memory.journal_entries(id) on delete restrict,
  memory_id uuid not null references master_memory.memory_items(id) on delete restrict,
  link_type master_memory.journal_memory_link_type not null default 'GENERATED',
  created_at timestamptz not null default now(),
  constraint journal_memory_links_entry_memory_type_key
    unique (journal_entry_id, memory_id, link_type)
);

create index journal_entries_owner_occurred_at_idx
  on master_memory.journal_entries(owner_id, occurred_at desc);

create index journal_entries_source_id_idx
  on master_memory.journal_entries(source_id);

create index journal_entries_current_revision_id_idx
  on master_memory.journal_entries(current_revision_id)
  where current_revision_id is not null;

create index journal_entries_original_text_search_idx
  on master_memory.journal_entries
  using gin(to_tsvector('simple', original_text));

create index journal_entry_revisions_entry_id_idx
  on master_memory.journal_entry_revisions(journal_entry_id, revision desc);

create index journal_entry_revisions_supersedes_id_idx
  on master_memory.journal_entry_revisions(supersedes_revision_id)
  where supersedes_revision_id is not null;

create index journal_entry_revisions_structured_text_search_idx
  on master_memory.journal_entry_revisions
  using gin(to_tsvector('simple', coalesce(structured_text, '')));

create index journal_revision_classifications_revision_id_idx
  on master_memory.journal_revision_classifications(journal_entry_revision_id);

create index journal_memory_links_entry_id_idx
  on master_memory.journal_memory_links(journal_entry_id);

create index journal_memory_links_memory_id_idx
  on master_memory.journal_memory_links(memory_id);

-- Raw journal text can never be rewritten. The entry pointer may only be moved
-- by the checked revision RPC below.
create function master_memory.prevent_journal_original_text_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if new.original_text is distinct from old.original_text then
    raise exception 'journal original_text is immutable; create a structured revision instead';
  end if;
  return new;
end;
$$;

create trigger journal_entries_preserve_original_text
  before update on master_memory.journal_entries
  for each row execute function master_memory.prevent_journal_original_text_mutation();

create trigger journal_entries_cannot_be_deleted
  before delete on master_memory.journal_entries
  for each row execute function master_memory.prevent_immutable_mutation();

create trigger journal_entry_revisions_are_immutable
  before update or delete on master_memory.journal_entry_revisions
  for each row execute function master_memory.prevent_immutable_mutation();

create trigger journal_revision_classifications_are_immutable
  before update or delete on master_memory.journal_revision_classifications
  for each row execute function master_memory.prevent_immutable_mutation();

create trigger journal_memory_links_are_immutable
  before update or delete on master_memory.journal_memory_links
  for each row execute function master_memory.prevent_immutable_mutation();

create function master_memory.validate_journal_current_revision_pointer()
returns trigger
language plpgsql
set search_path = pg_catalog, master_memory
as $$
declare
  v_revision_entry_id uuid;
begin
  if new.current_revision_id is null then
    return new;
  end if;

  select journal_entry_id
  into v_revision_entry_id
  from master_memory.journal_entry_revisions
  where id = new.current_revision_id;

  if not found or v_revision_entry_id <> new.id then
    raise exception 'current_revision_id must belong to its journal entry';
  end if;

  return new;
end;
$$;

create trigger journal_entries_validate_current_revision_pointer
  before insert or update of current_revision_id on master_memory.journal_entries
  for each row execute function master_memory.validate_journal_current_revision_pointer();

create function master_memory.validate_journal_revision_lineage()
returns trigger
language plpgsql
set search_path = pg_catalog, master_memory
as $$
declare
  v_predecessor_entry_id uuid;
  v_predecessor_revision integer;
begin
  if new.revision = 1 and new.supersedes_revision_id is not null then
    raise exception 'journal revision 1 cannot supersede another revision';
  end if;

  if new.revision > 1 and new.supersedes_revision_id is null then
    raise exception 'successor journal revisions must identify the revision they supersede';
  end if;

  if new.supersedes_revision_id is null then
    return new;
  end if;

  select journal_entry_id, revision
  into v_predecessor_entry_id, v_predecessor_revision
  from master_memory.journal_entry_revisions
  where id = new.supersedes_revision_id;

  if not found
    or v_predecessor_entry_id <> new.journal_entry_id
    or v_predecessor_revision <> new.revision - 1 then
    raise exception 'a journal revision must supersede the immediately previous revision of the same entry';
  end if;

  return new;
end;
$$;

create trigger journal_entry_revisions_validate_lineage
  before insert on master_memory.journal_entry_revisions
  for each row execute function master_memory.validate_journal_revision_lineage();

-- This internal view derives SUPERSEDED without changing historic revisions.
create view master_memory.journal_revision_status
with (security_invoker = true)
as
select
  je.owner_id,
  je.id as journal_entry_id,
  je.occurred_at,
  je.original_text,
  je.source_id,
  je.project_reference,
  je.current_revision_id,
  je.created_at as journal_created_at,
  je.updated_at as journal_updated_at,
  jer.id as revision_id,
  jer.revision,
  jer.supersedes_revision_id,
  jer.title,
  jer.structured_text,
  jer.structured_data,
  case
    when je.current_revision_id is distinct from jer.id then 'SUPERSEDED'::master_memory.memory_status
    else jer.status
  end as effective_status,
  jer.sensitivity,
  jer.created_at,
  jer.updated_at
from master_memory.journal_entries je
join master_memory.journal_entry_revisions jer on jer.journal_entry_id = je.id;

create function master_memory.create_journal_entry(
  p_occurred_at timestamptz,
  p_original_text text,
  p_source_id uuid,
  p_title text default null,
  p_structured_text text default null,
  p_structured_data jsonb default '{}'::jsonb,
  p_status master_memory.memory_status default 'CURRENT',
  p_sensitivity master_memory.sensitivity_level default 'PRIVATE',
  p_project_reference text default null,
  p_classifications master_memory.journal_entry_classification[] default array[]::master_memory.journal_entry_classification[]
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner_id uuid := auth.uid();
  v_journal_entry_id uuid;
  v_revision_id uuid;
begin
  if v_owner_id is null then
    raise exception 'an authenticated owner is required';
  end if;

  if p_status = 'SUPERSEDED' then
    raise exception 'a new journal entry cannot be created as SUPERSEDED';
  end if;

  if not exists (
    select 1 from master_memory.memory_sources
    where id = p_source_id and owner_id = v_owner_id
  ) then
    raise exception 'source does not belong to the authenticated owner';
  end if;

  insert into master_memory.journal_entries (
    owner_id, occurred_at, original_text, source_id, project_reference
  )
  values (
    v_owner_id, p_occurred_at, p_original_text, p_source_id, p_project_reference
  )
  returning id into v_journal_entry_id;

  insert into master_memory.journal_entry_revisions (
    journal_entry_id, revision, title, structured_text, structured_data, status, sensitivity
  )
  values (
    v_journal_entry_id, 1, p_title, p_structured_text,
    coalesce(p_structured_data, '{}'::jsonb), p_status, p_sensitivity
  )
  returning id into v_revision_id;

  insert into master_memory.journal_revision_classifications (
    journal_entry_revision_id, classification
  )
  select v_revision_id, classification
  from unnest(coalesce(p_classifications, array[]::master_memory.journal_entry_classification[])) as classification
  on conflict do nothing;

  update master_memory.journal_entries
  set current_revision_id = v_revision_id,
      updated_at = now()
  where id = v_journal_entry_id;

  return v_journal_entry_id;
end;
$$;

create function master_memory.create_journal_revision(
  p_journal_entry_id uuid,
  p_title text,
  p_structured_text text,
  p_structured_data jsonb default '{}'::jsonb,
  p_status master_memory.memory_status default 'CURRENT',
  p_sensitivity master_memory.sensitivity_level default 'PRIVATE',
  p_classifications master_memory.journal_entry_classification[] default array[]::master_memory.journal_entry_classification[]
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner_id uuid := auth.uid();
  v_previous_revision_id uuid;
  v_revision_id uuid;
  v_next_revision integer;
begin
  if v_owner_id is null then
    raise exception 'an authenticated owner is required';
  end if;

  if p_status = 'SUPERSEDED' then
    raise exception 'a successor journal revision cannot be created as SUPERSEDED';
  end if;

  select current_revision_id
  into v_previous_revision_id
  from master_memory.journal_entries
  where id = p_journal_entry_id and owner_id = v_owner_id
  for update;

  if not found or v_previous_revision_id is null then
    raise exception 'journal entry does not belong to the authenticated owner';
  end if;

  select coalesce(max(revision), 0) + 1
  into v_next_revision
  from master_memory.journal_entry_revisions
  where journal_entry_id = p_journal_entry_id;

  insert into master_memory.journal_entry_revisions (
    journal_entry_id, revision, supersedes_revision_id, title, structured_text,
    structured_data, status, sensitivity
  )
  values (
    p_journal_entry_id, v_next_revision, v_previous_revision_id, p_title,
    p_structured_text, coalesce(p_structured_data, '{}'::jsonb), p_status,
    p_sensitivity
  )
  returning id into v_revision_id;

  insert into master_memory.journal_revision_classifications (
    journal_entry_revision_id, classification
  )
  select v_revision_id, classification
  from unnest(coalesce(p_classifications, array[]::master_memory.journal_entry_classification[])) as classification
  on conflict do nothing;

  update master_memory.journal_entries
  set current_revision_id = v_revision_id,
      updated_at = now()
  where id = p_journal_entry_id;

  return v_revision_id;
end;
$$;

create function master_memory.link_journal_memory(
  p_journal_entry_id uuid,
  p_memory_id uuid,
  p_link_type master_memory.journal_memory_link_type default 'GENERATED'
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner_id uuid := auth.uid();
  v_link_id uuid;
begin
  if v_owner_id is null then
    raise exception 'an authenticated owner is required';
  end if;

  if not exists (
    select 1 from master_memory.journal_entries
    where id = p_journal_entry_id and owner_id = v_owner_id
  ) then
    raise exception 'journal entry does not belong to the authenticated owner';
  end if;

  if not exists (
    select 1 from master_memory.memory_items
    where id = p_memory_id and owner_id = v_owner_id
  ) then
    raise exception 'memory item does not belong to the authenticated owner';
  end if;

  insert into master_memory.journal_memory_links (
    journal_entry_id, memory_id, link_type
  )
  values (p_journal_entry_id, p_memory_id, p_link_type)
  on conflict do nothing
  returning id into v_link_id;

  if v_link_id is null then
    select id into v_link_id
    from master_memory.journal_memory_links
    where journal_entry_id = p_journal_entry_id
      and memory_id = p_memory_id
      and link_type = p_link_type;
  end if;

  return v_link_id;
end;
$$;

create function master_memory.search_journal(
  p_query text default null,
  p_include_history boolean default false,
  p_include_highly_sensitive boolean default false
)
returns table (
  journal_entry_id uuid,
  revision_id uuid,
  revision integer,
  occurred_at timestamptz,
  title text,
  original_text text,
  structured_text text,
  structured_data jsonb,
  status master_memory.memory_status,
  sensitivity master_memory.sensitivity_level,
  source_id uuid,
  project_reference text,
  classifications jsonb,
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
    jrs.journal_entry_id,
    jrs.revision_id,
    jrs.revision,
    jrs.occurred_at,
    jrs.title,
    jrs.original_text,
    jrs.structured_text,
    jrs.structured_data,
    jrs.effective_status,
    jrs.sensitivity,
    jrs.source_id,
    jrs.project_reference,
    coalesce((
      select jsonb_agg(jrc.classification order by jrc.classification)
      from master_memory.journal_revision_classifications jrc
      where jrc.journal_entry_revision_id = jrs.revision_id
    ), '[]'::jsonb),
    jrs.updated_at
  from master_memory.journal_revision_status jrs
  where jrs.owner_id = v_owner_id
    and (p_include_history or jrs.revision_id = jrs.current_revision_id)
    and (p_include_highly_sensitive or jrs.sensitivity <> 'HIGHLY_SENSITIVE')
    and (
      v_query is null
      or to_tsvector('simple', jrs.original_text) @@ websearch_to_tsquery('simple', v_query)
      or to_tsvector('simple', coalesce(jrs.structured_text, '')) @@ websearch_to_tsquery('simple', v_query)
    )
  order by jrs.occurred_at desc, jrs.updated_at desc;
end;
$$;

-- Portable, complete export. Passing true is an explicit request to include
-- HIGHLY_SENSITIVE entries; the safe default excludes them.
create function master_memory.export_master_memory_json(
  p_include_highly_sensitive boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner_id uuid := auth.uid();
begin
  if v_owner_id is null then
    raise exception 'an authenticated owner is required';
  end if;

  return jsonb_build_object(
    'format_version', '0.2',
    'exported_at', now(),
    'memory_items', coalesce((
      select jsonb_agg(to_jsonb(mi) order by mi.created_at)
      from master_memory.memory_items mi
      join master_memory.memory_versions current_mv on current_mv.id = mi.current_version_id
      where mi.owner_id = v_owner_id
        and (p_include_highly_sensitive or current_mv.sensitivity <> 'HIGHLY_SENSITIVE')
    ), '[]'::jsonb),
    'memory_versions', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'record', to_jsonb(mv) - 'search_vector',
          'effective_status', mvs.effective_status
        ) order by mv.memory_id, mv.version
      )
      from master_memory.memory_versions mv
      join master_memory.memory_version_status mvs on mvs.version_id = mv.id
      where mvs.owner_id = v_owner_id
        and (p_include_highly_sensitive or mv.sensitivity <> 'HIGHLY_SENSITIVE')
    ), '[]'::jsonb),
    'memory_sources', coalesce((
      select jsonb_agg(to_jsonb(ms) order by ms.created_at)
      from master_memory.memory_sources ms
      where ms.owner_id = v_owner_id
        and (
          p_include_highly_sensitive
          or exists (
            select 1 from master_memory.memory_versions mv
            join master_memory.memory_items mi on mi.id = mv.memory_id
            where mv.source_id = ms.id
              and mi.owner_id = v_owner_id
              and mv.sensitivity <> 'HIGHLY_SENSITIVE'
          )
          or exists (
            select 1 from master_memory.journal_entries je
            join master_memory.journal_entry_revisions jer on jer.id = je.current_revision_id
            where je.source_id = ms.id
              and je.owner_id = v_owner_id
              and jer.sensitivity <> 'HIGHLY_SENSITIVE'
          )
        )
    ), '[]'::jsonb),
    'memory_intake_records', coalesce((
      select jsonb_agg(to_jsonb(mir) order by mir.created_at)
      from master_memory.memory_intake_records mir
      left join master_memory.memory_items mi on mi.id = mir.memory_id
      left join master_memory.memory_versions current_mv on current_mv.id = mi.current_version_id
      where mir.owner_id = v_owner_id
        and (
          p_include_highly_sensitive
          or mir.memory_id is null
          or current_mv.sensitivity <> 'HIGHLY_SENSITIVE'
        )
    ), '[]'::jsonb),
    'journal_entries', coalesce((
      select jsonb_agg(to_jsonb(je) order by je.occurred_at)
      from master_memory.journal_entries je
      join master_memory.journal_entry_revisions current_jer on current_jer.id = je.current_revision_id
      where je.owner_id = v_owner_id
        and (p_include_highly_sensitive or current_jer.sensitivity <> 'HIGHLY_SENSITIVE')
    ), '[]'::jsonb),
    'journal_entry_revisions', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'record', to_jsonb(jer),
          'effective_status', jrs.effective_status
        ) order by jer.journal_entry_id, jer.revision
      )
      from master_memory.journal_entry_revisions jer
      join master_memory.journal_revision_status jrs on jrs.revision_id = jer.id
      where jrs.owner_id = v_owner_id
        and (p_include_highly_sensitive or jer.sensitivity <> 'HIGHLY_SENSITIVE')
    ), '[]'::jsonb),
    'journal_revision_classifications', coalesce((
      select jsonb_agg(to_jsonb(jrc) order by jrc.created_at)
      from master_memory.journal_revision_classifications jrc
      join master_memory.journal_entry_revisions jer on jer.id = jrc.journal_entry_revision_id
      join master_memory.journal_entries je on je.id = jer.journal_entry_id
      where je.owner_id = v_owner_id
        and (p_include_highly_sensitive or jer.sensitivity <> 'HIGHLY_SENSITIVE')
    ), '[]'::jsonb),
    'journal_memory_links', coalesce((
      select jsonb_agg(to_jsonb(jml) order by jml.created_at)
      from master_memory.journal_memory_links jml
      join master_memory.journal_entries je on je.id = jml.journal_entry_id
      join master_memory.journal_entry_revisions jer on jer.id = je.current_revision_id
      join master_memory.memory_items mi on mi.id = jml.memory_id
      join master_memory.memory_versions mv on mv.id = mi.current_version_id
      where je.owner_id = v_owner_id
        and (p_include_highly_sensitive or (
          jer.sensitivity <> 'HIGHLY_SENSITIVE'
          and mv.sensitivity <> 'HIGHLY_SENSITIVE'
        ))
    ), '[]'::jsonb)
  );
end;
$$;

create function master_memory.export_master_memory_markdown(
  p_include_highly_sensitive boolean default false
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner_id uuid := auth.uid();
  v_sources text;
  v_memories text;
  v_journal text;
  v_intake text;
  v_links text;
begin
  if v_owner_id is null then
    raise exception 'an authenticated owner is required';
  end if;

  select coalesce(string_agg(
    format('- `%s` — %s (%s)', ms.id, ms.source_label, ms.source_type),
    E'\n' order by ms.created_at
  ), '_Nessuna fonte esportabile._')
  into v_sources
  from master_memory.memory_sources ms
  where ms.owner_id = v_owner_id
    and (
      p_include_highly_sensitive
      or exists (
        select 1 from master_memory.memory_versions mv
        join master_memory.memory_items mi on mi.id = mv.memory_id
        where mv.source_id = ms.id and mi.owner_id = v_owner_id
          and mv.sensitivity <> 'HIGHLY_SENSITIVE'
      )
      or exists (
        select 1 from master_memory.journal_entries je
        join master_memory.journal_entry_revisions jer on jer.id = je.current_revision_id
        where je.source_id = ms.id and je.owner_id = v_owner_id
          and jer.sensitivity <> 'HIGHLY_SENSITIVE'
      )
    );

  select coalesce(string_agg(
    format(
      '### %s — versione %s\n- ID memoria: `%s`\n- Stato: `%s`\n- Sensibilità: `%s`\n- Fonte: `%s`\n\n%s',
      mvs.title, mvs.version, mvs.memory_id, mvs.effective_status,
      mvs.sensitivity, mvs.source_id, mvs.content
    ),
    E'\n\n' order by mvs.memory_id, mvs.version
  ), '_Nessuna memoria esportabile._')
  into v_memories
  from master_memory.memory_version_status mvs
  where mvs.owner_id = v_owner_id
    and (p_include_highly_sensitive or mvs.sensitivity <> 'HIGHLY_SENSITIVE');

  select coalesce(string_agg(
    format(
      '### %s — revisione %s\n- ID journal: `%s`\n- Stato: `%s`\n- Sensibilità: `%s`\n- Fonte: `%s`\n\n**Originale**\n\n%s\n\n**Strutturato**\n\n%s',
      coalesce(jrs.title, 'Journal entry'), jrs.revision, jrs.journal_entry_id,
      jrs.effective_status, jrs.sensitivity, jrs.source_id, jrs.original_text,
      coalesce(jrs.structured_text, '_Non ancora strutturato._')
    ),
    E'\n\n' order by jrs.occurred_at, jrs.revision
  ), '_Nessuna journal entry esportabile._')
  into v_journal
  from master_memory.journal_revision_status jrs
  where jrs.owner_id = v_owner_id
    and (p_include_highly_sensitive or jrs.sensitivity <> 'HIGHLY_SENSITIVE');

  select coalesce(string_agg(
    format('- `%s`: %s (%s)', mir.id, mir.presence_state, mir.acquisition_mode),
    E'\n' order by mir.created_at
  ), '_Nessun intake record esportabile._')
  into v_intake
  from master_memory.memory_intake_records mir
  left join master_memory.memory_items mi on mi.id = mir.memory_id
  left join master_memory.memory_versions current_mv on current_mv.id = mi.current_version_id
  where mir.owner_id = v_owner_id
    and (
      p_include_highly_sensitive
      or mir.memory_id is null
      or current_mv.sensitivity <> 'HIGHLY_SENSITIVE'
    );

  select coalesce(string_agg(
    format('- Journal `%s` → Memory `%s` (%s)', jml.journal_entry_id, jml.memory_id, jml.link_type),
    E'\n' order by jml.created_at
  ), '_Nessuna relazione esportabile._')
  into v_links
  from master_memory.journal_memory_links jml
  join master_memory.journal_entries je on je.id = jml.journal_entry_id
  join master_memory.journal_entry_revisions jer on jer.id = je.current_revision_id
  join master_memory.memory_items mi on mi.id = jml.memory_id
  join master_memory.memory_versions mv on mv.id = mi.current_version_id
  where je.owner_id = v_owner_id
    and (p_include_highly_sensitive or (
      jer.sensitivity <> 'HIGHLY_SENSITIVE'
      and mv.sensitivity <> 'HIGHLY_SENSITIVE'
    ));

  return format(
    '# NEACEA MASTER MEMORY export\n\nEsportato: %s\n\n## Fonti\n\n%s\n\n## Memory versions\n\n%s\n\n## Journal\n\n%s\n\n## Intake records\n\n%s\n\n## Relazioni Journal → Memory\n\n%s\n',
    now(), v_sources, v_memories, v_journal, v_intake, v_links
  );
end;
$$;

-- Private tables retain V0.1's deny-by-default model. Policies document the
-- intended owner boundary if a controlled direct-access path is added later.
alter table master_memory.journal_entries enable row level security;
alter table master_memory.journal_entries force row level security;
alter table master_memory.journal_entry_revisions enable row level security;
alter table master_memory.journal_entry_revisions force row level security;
alter table master_memory.journal_revision_classifications enable row level security;
alter table master_memory.journal_revision_classifications force row level security;
alter table master_memory.journal_memory_links enable row level security;
alter table master_memory.journal_memory_links force row level security;

create policy journal_entries_select_own
  on master_memory.journal_entries
  for select
  to authenticated
  using (owner_id = (select auth.uid()));

create policy journal_entry_revisions_select_own
  on master_memory.journal_entry_revisions
  for select
  to authenticated
  using (
    exists (
      select 1 from master_memory.journal_entries je
      where je.id = journal_entry_revisions.journal_entry_id
        and je.owner_id = (select auth.uid())
    )
  );

create policy journal_revision_classifications_select_own
  on master_memory.journal_revision_classifications
  for select
  to authenticated
  using (
    exists (
      select 1
      from master_memory.journal_entry_revisions jer
      join master_memory.journal_entries je on je.id = jer.journal_entry_id
      where jer.id = journal_revision_classifications.journal_entry_revision_id
        and je.owner_id = (select auth.uid())
    )
  );

create policy journal_memory_links_select_own
  on master_memory.journal_memory_links
  for select
  to authenticated
  using (
    exists (
      select 1 from master_memory.journal_entries je
      where je.id = journal_memory_links.journal_entry_id
        and je.owner_id = (select auth.uid())
    )
  );

revoke all on table master_memory.journal_entries from public, anon, authenticated;
revoke all on table master_memory.journal_entry_revisions from public, anon, authenticated;
revoke all on table master_memory.journal_revision_classifications from public, anon, authenticated;
revoke all on table master_memory.journal_memory_links from public, anon, authenticated;

revoke all on function master_memory.prevent_journal_original_text_mutation() from public, anon, authenticated;
revoke all on function master_memory.validate_journal_current_revision_pointer() from public, anon, authenticated;
revoke all on function master_memory.validate_journal_revision_lineage() from public, anon, authenticated;
revoke all on function master_memory.create_journal_entry(
  timestamptz, text, uuid, text, text, jsonb, master_memory.memory_status,
  master_memory.sensitivity_level, text, master_memory.journal_entry_classification[]
) from public, anon, authenticated;
revoke all on function master_memory.create_journal_revision(
  uuid, text, text, jsonb, master_memory.memory_status,
  master_memory.sensitivity_level, master_memory.journal_entry_classification[]
) from public, anon, authenticated;
revoke all on function master_memory.link_journal_memory(
  uuid, uuid, master_memory.journal_memory_link_type
) from public, anon, authenticated;
revoke all on function master_memory.search_journal(text, boolean, boolean) from public, anon, authenticated;
revoke all on function master_memory.export_master_memory_json(boolean) from public, anon, authenticated;
revoke all on function master_memory.export_master_memory_markdown(boolean) from public, anon, authenticated;

grant execute on function master_memory.create_journal_entry(
  timestamptz, text, uuid, text, text, jsonb, master_memory.memory_status,
  master_memory.sensitivity_level, text, master_memory.journal_entry_classification[]
) to authenticated;
grant execute on function master_memory.create_journal_revision(
  uuid, text, text, jsonb, master_memory.memory_status,
  master_memory.sensitivity_level, master_memory.journal_entry_classification[]
) to authenticated;
grant execute on function master_memory.link_journal_memory(
  uuid, uuid, master_memory.journal_memory_link_type
) to authenticated;
grant execute on function master_memory.search_journal(text, boolean, boolean)
  to authenticated;
grant execute on function master_memory.export_master_memory_json(boolean)
  to authenticated;
grant execute on function master_memory.export_master_memory_markdown(boolean)
  to authenticated;

commit;
