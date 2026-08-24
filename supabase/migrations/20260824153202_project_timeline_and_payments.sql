begin;

-- V0.3 project model. Project rows are intentionally empty at this stage.
create type master_memory.project_status as enum (
  'PLANNED', 'ACTIVE', 'PAUSED', 'COMPLETED', 'ARCHIVED'
);

create type master_memory.project_phase as enum (
  'IDEA', 'DESIGN', 'FINANCING', 'LOCATION_RESEARCH', 'WORKS',
  'AUTHORIZATIONS', 'EQUIPMENT_PURCHASE', 'FIT_OUT', 'OPENING',
  'OPERATIONS', 'EVOLUTION'
);

create type master_memory.project_timeline_event_type as enum (
  'JOURNAL_ENTRY', 'MEMORY_ITEM', 'DECISION', 'PAYMENT', 'DOCUMENT', 'MILESTONE'
);

create type master_memory.project_payment_link_type as enum (
  'RECORDED', 'REFERENCED'
);

create table master_memory.projects (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  name text not null check (char_length(btrim(name)) > 0),
  description text,
  project_type text not null check (char_length(btrim(project_type)) > 0),
  status master_memory.project_status not null default 'PLANNED',
  sensitivity master_memory.sensitivity_level not null default 'PRIVATE',
  start_date date,
  end_date date,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint projects_date_order_check
    check (end_date is null or start_date is null or end_date >= start_date)
);

create table master_memory.project_status_history (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references master_memory.projects(id) on delete restrict,
  previous_status master_memory.project_status,
  new_status master_memory.project_status not null,
  changed_at timestamptz not null default now(),
  changed_by uuid not null references auth.users(id) on delete restrict,
  reason text,
  source_id uuid references master_memory.memory_sources(id) on delete restrict,
  metadata jsonb not null default '{}'::jsonb,
  constraint project_status_history_transition_check
    check (previous_status is null or previous_status <> new_status)
);

create table master_memory.project_payments (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  project_id uuid references master_memory.projects(id) on delete restrict,
  payment_date date not null,
  amount numeric(14,2) not null check (amount >= 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  description text not null check (char_length(btrim(description)) > 0),
  category text not null check (char_length(btrim(category)) > 0),
  supplier text,
  source_id uuid not null references master_memory.memory_sources(id) on delete restrict,
  sensitivity master_memory.sensitivity_level not null default 'PRIVATE',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table master_memory.project_timeline_entries (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references master_memory.projects(id) on delete restrict,
  owner_id uuid not null references auth.users(id) on delete restrict,
  occurred_at timestamptz not null,
  event_type master_memory.project_timeline_event_type not null,
  title text,
  description text,
  phase master_memory.project_phase,
  journal_entry_id uuid references master_memory.journal_entries(id) on delete restrict,
  memory_id uuid references master_memory.memory_items(id) on delete restrict,
  payment_id uuid references master_memory.project_payments(id) on delete restrict,
  source_id uuid references master_memory.memory_sources(id) on delete restrict,
  milestone_key text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint project_timeline_target_check check (
    (event_type = 'JOURNAL_ENTRY' and journal_entry_id is not null and memory_id is null and payment_id is null and source_id is null and milestone_key is null)
    or (event_type in ('MEMORY_ITEM', 'DECISION') and journal_entry_id is null and memory_id is not null and payment_id is null and source_id is null and milestone_key is null)
    or (event_type = 'PAYMENT' and journal_entry_id is null and memory_id is null and payment_id is not null and source_id is null and milestone_key is null)
    or (event_type = 'DOCUMENT' and journal_entry_id is null and memory_id is null and payment_id is null and source_id is not null and milestone_key is null)
    or (event_type = 'MILESTONE' and journal_entry_id is null and memory_id is null and payment_id is null and source_id is null and milestone_key is not null and char_length(btrim(milestone_key)) > 0)
  )
);

create table master_memory.journal_payment_links (
  id uuid primary key default gen_random_uuid(),
  journal_entry_id uuid not null references master_memory.journal_entries(id) on delete restrict,
  payment_id uuid not null references master_memory.project_payments(id) on delete restrict,
  link_type master_memory.project_payment_link_type not null default 'RECORDED',
  created_at timestamptz not null default now(),
  constraint journal_payment_links_unique_key unique (journal_entry_id, payment_id, link_type)
);

create table master_memory.project_sources (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references master_memory.projects(id) on delete restrict,
  source_id uuid not null references master_memory.memory_sources(id) on delete restrict,
  source_role text not null default 'DOCUMENT' check (char_length(btrim(source_role)) > 0),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint project_sources_unique_key unique (project_id, source_id)
);

create index projects_owner_status_idx on master_memory.projects(owner_id, status);
create index projects_owner_updated_at_idx on master_memory.projects(owner_id, updated_at desc);
create index projects_name_search_idx on master_memory.projects using gin(to_tsvector('simple', name || ' ' || coalesce(description, '')));
create index project_status_history_project_changed_at_idx on master_memory.project_status_history(project_id, changed_at desc);
create index project_status_history_source_id_idx on master_memory.project_status_history(source_id) where source_id is not null;
create index project_payments_owner_date_idx on master_memory.project_payments(owner_id, payment_date desc);
create index project_payments_project_date_idx on master_memory.project_payments(project_id, payment_date desc) where project_id is not null;
create index project_payments_source_id_idx on master_memory.project_payments(source_id);
create index project_timeline_project_occurred_at_idx on master_memory.project_timeline_entries(project_id, occurred_at desc);
create index project_timeline_owner_occurred_at_idx on master_memory.project_timeline_entries(owner_id, occurred_at desc);
create index project_timeline_phase_idx on master_memory.project_timeline_entries(project_id, phase) where phase is not null;
create index project_timeline_journal_id_idx on master_memory.project_timeline_entries(journal_entry_id) where journal_entry_id is not null;
create index project_timeline_memory_id_idx on master_memory.project_timeline_entries(memory_id) where memory_id is not null;
create index project_timeline_payment_id_idx on master_memory.project_timeline_entries(payment_id) where payment_id is not null;
create index project_timeline_source_id_idx on master_memory.project_timeline_entries(source_id) where source_id is not null;
create index journal_payment_links_journal_id_idx on master_memory.journal_payment_links(journal_entry_id);
create index journal_payment_links_payment_id_idx on master_memory.journal_payment_links(payment_id);
create index project_sources_project_id_idx on master_memory.project_sources(project_id);
create index project_sources_source_id_idx on master_memory.project_sources(source_id);

create trigger projects_cannot_be_deleted
  before delete on master_memory.projects
  for each row execute function master_memory.prevent_immutable_mutation();
create trigger project_status_history_is_immutable
  before update or delete on master_memory.project_status_history
  for each row execute function master_memory.prevent_immutable_mutation();
create trigger project_timeline_entries_are_immutable
  before update or delete on master_memory.project_timeline_entries
  for each row execute function master_memory.prevent_immutable_mutation();
create trigger journal_payment_links_are_immutable
  before update or delete on master_memory.journal_payment_links
  for each row execute function master_memory.prevent_immutable_mutation();
create trigger project_sources_are_immutable
  before update or delete on master_memory.project_sources
  for each row execute function master_memory.prevent_immutable_mutation();

create function master_memory.create_project(
  p_name text,
  p_description text default null,
  p_project_type text default 'GENERAL',
  p_status master_memory.project_status default 'PLANNED',
  p_sensitivity master_memory.sensitivity_level default 'PRIVATE',
  p_start_date date default null,
  p_end_date date default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner uuid := (select auth.uid());
  v_project_id uuid;
begin
  if v_owner is null then raise exception 'authentication required'; end if;
  insert into master_memory.projects(owner_id, name, description, project_type, status, sensitivity, start_date, end_date, metadata)
  values (v_owner, p_name, p_description, p_project_type, p_status, p_sensitivity, p_start_date, p_end_date, p_metadata)
  returning id into v_project_id;
  insert into master_memory.project_status_history(project_id, previous_status, new_status, changed_by)
  values (v_project_id, null, p_status, v_owner);
  return v_project_id;
end;
$$;

create function master_memory.transition_project_status(
  p_project_id uuid,
  p_new_status master_memory.project_status,
  p_reason text default null,
  p_source_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner uuid := (select auth.uid());
  v_previous master_memory.project_status;
  v_history_id uuid;
begin
  if v_owner is null then raise exception 'authentication required'; end if;
  select status into v_previous from master_memory.projects where id = p_project_id and owner_id = v_owner for update;
  if not found then raise exception 'project not found'; end if;
  if v_previous = p_new_status then raise exception 'project already has this status'; end if;
  if p_source_id is not null and not exists (
    select 1 from master_memory.memory_sources where id = p_source_id and owner_id = v_owner
  ) then raise exception 'source not found'; end if;
  update master_memory.projects set status = p_new_status, updated_at = now() where id = p_project_id;
  insert into master_memory.project_status_history(project_id, previous_status, new_status, changed_by, reason, source_id, metadata)
  values (p_project_id, v_previous, p_new_status, v_owner, p_reason, p_source_id, p_metadata)
  returning id into v_history_id;
  return v_history_id;
end;
$$;

create function master_memory.create_project_payment(
  p_payment_date date,
  p_amount numeric,
  p_currency text,
  p_description text,
  p_category text,
  p_source_id uuid,
  p_project_id uuid default null,
  p_supplier text default null,
  p_sensitivity master_memory.sensitivity_level default 'PRIVATE',
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner uuid := (select auth.uid());
  v_payment_id uuid;
begin
  if v_owner is null then raise exception 'authentication required'; end if;
  if not exists (select 1 from master_memory.memory_sources where id = p_source_id and owner_id = v_owner) then
    raise exception 'source not found';
  end if;
  if p_project_id is not null and not exists (select 1 from master_memory.projects where id = p_project_id and owner_id = v_owner) then
    raise exception 'project not found';
  end if;
  insert into master_memory.project_payments(owner_id, project_id, payment_date, amount, currency, description, category, supplier, source_id, sensitivity, metadata)
  values (v_owner, p_project_id, p_payment_date, p_amount, upper(p_currency), p_description, p_category, p_supplier, p_source_id, p_sensitivity, p_metadata)
  returning id into v_payment_id;
  return v_payment_id;
end;
$$;

create function master_memory.add_project_timeline_entry(
  p_project_id uuid,
  p_occurred_at timestamptz,
  p_event_type master_memory.project_timeline_event_type,
  p_title text default null,
  p_description text default null,
  p_phase master_memory.project_phase default null,
  p_journal_entry_id uuid default null,
  p_memory_id uuid default null,
  p_payment_id uuid default null,
  p_source_id uuid default null,
  p_milestone_key text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner uuid := (select auth.uid());
  v_id uuid;
begin
  if v_owner is null then raise exception 'authentication required'; end if;
  if not exists (select 1 from master_memory.projects where id = p_project_id and owner_id = v_owner) then raise exception 'project not found'; end if;
  if p_journal_entry_id is not null and not exists (select 1 from master_memory.journal_entries where id = p_journal_entry_id and owner_id = v_owner) then raise exception 'journal entry not found'; end if;
  if p_memory_id is not null and not exists (select 1 from master_memory.memory_items where id = p_memory_id and owner_id = v_owner) then raise exception 'memory item not found'; end if;
  if p_payment_id is not null and not exists (select 1 from master_memory.project_payments where id = p_payment_id and owner_id = v_owner) then raise exception 'payment not found'; end if;
  if p_source_id is not null and not exists (select 1 from master_memory.memory_sources where id = p_source_id and owner_id = v_owner) then raise exception 'source not found'; end if;
  insert into master_memory.project_timeline_entries(project_id, owner_id, occurred_at, event_type, title, description, phase, journal_entry_id, memory_id, payment_id, source_id, milestone_key, metadata)
  values (p_project_id, v_owner, p_occurred_at, p_event_type, p_title, p_description, p_phase, p_journal_entry_id, p_memory_id, p_payment_id, p_source_id, p_milestone_key, p_metadata)
  returning id into v_id;
  return v_id;
end;
$$;

create function master_memory.link_journal_payment(
  p_journal_entry_id uuid,
  p_payment_id uuid,
  p_link_type master_memory.project_payment_link_type default 'RECORDED'
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner uuid := (select auth.uid());
  v_id uuid;
begin
  if v_owner is null then raise exception 'authentication required'; end if;
  if not exists (select 1 from master_memory.journal_entries where id = p_journal_entry_id and owner_id = v_owner) then raise exception 'journal entry not found'; end if;
  if not exists (select 1 from master_memory.project_payments where id = p_payment_id and owner_id = v_owner) then raise exception 'payment not found'; end if;
  insert into master_memory.journal_payment_links(journal_entry_id, payment_id, link_type)
  values (p_journal_entry_id, p_payment_id, p_link_type)
  on conflict (journal_entry_id, payment_id, link_type) do update set link_type = excluded.link_type
  returning id into v_id;
  return v_id;
end;
$$;

create function master_memory.link_project_source(
  p_project_id uuid,
  p_source_id uuid,
  p_source_role text default 'DOCUMENT',
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner uuid := (select auth.uid());
  v_id uuid;
begin
  if v_owner is null then raise exception 'authentication required'; end if;
  if not exists (select 1 from master_memory.projects where id = p_project_id and owner_id = v_owner) then raise exception 'project not found'; end if;
  if not exists (select 1 from master_memory.memory_sources where id = p_source_id and owner_id = v_owner) then raise exception 'source not found'; end if;
  insert into master_memory.project_sources(project_id, source_id, source_role, metadata)
  values (p_project_id, p_source_id, p_source_role, p_metadata)
  on conflict (project_id, source_id) do update set source_role = excluded.source_role, metadata = excluded.metadata
  returning id into v_id;
  return v_id;
end;
$$;

-- Replace the V0.2 exports with V0.3-compatible wrappers while retaining the
-- old implementations as private helpers for the pre-existing sections.
alter function master_memory.export_master_memory_json(boolean) rename to export_master_memory_v02_json;
alter function master_memory.export_master_memory_markdown(boolean) rename to export_master_memory_v02_markdown;

create function master_memory.export_master_memory_json(p_include_highly_sensitive boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner uuid := (select auth.uid());
  v_base jsonb;
begin
  if v_owner is null then raise exception 'authentication required'; end if;
  v_base := master_memory.export_master_memory_v02_json(p_include_highly_sensitive);
  return v_base || jsonb_build_object(
    'format_version', '0.3',
    'projects', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at) from master_memory.projects p where p.owner_id = v_owner and (p_include_highly_sensitive or p.sensitivity <> 'HIGHLY_SENSITIVE')), '[]'::jsonb),
    'project_status_history', coalesce((select jsonb_agg(to_jsonb(h) order by h.changed_at) from master_memory.project_status_history h join master_memory.projects p on p.id = h.project_id where p.owner_id = v_owner and (p_include_highly_sensitive or p.sensitivity <> 'HIGHLY_SENSITIVE')), '[]'::jsonb),
    'project_timeline_entries', coalesce((select jsonb_agg(to_jsonb(t) order by t.occurred_at) from master_memory.project_timeline_entries t join master_memory.projects p on p.id = t.project_id where p.owner_id = v_owner and (p_include_highly_sensitive or p.sensitivity <> 'HIGHLY_SENSITIVE')), '[]'::jsonb),
    'project_payments', coalesce((select jsonb_agg(to_jsonb(pay) order by pay.payment_date) from master_memory.project_payments pay left join master_memory.projects p on p.id = pay.project_id where pay.owner_id = v_owner and (p_include_highly_sensitive or (pay.sensitivity <> 'HIGHLY_SENSITIVE' and (p.id is null or p.sensitivity <> 'HIGHLY_SENSITIVE')))), '[]'::jsonb),
    'journal_payment_links', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at) from master_memory.journal_payment_links l join master_memory.journal_entries je on je.id = l.journal_entry_id join master_memory.project_payments pay on pay.id = l.payment_id left join master_memory.projects p on p.id = pay.project_id where je.owner_id = v_owner and (p_include_highly_sensitive or (pay.sensitivity <> 'HIGHLY_SENSITIVE' and (p.id is null or p.sensitivity <> 'HIGHLY_SENSITIVE')))), '[]'::jsonb),
    'project_sources', coalesce((select jsonb_agg(to_jsonb(ps) order by ps.created_at) from master_memory.project_sources ps join master_memory.projects p on p.id = ps.project_id where p.owner_id = v_owner and (p_include_highly_sensitive or p.sensitivity <> 'HIGHLY_SENSITIVE')), '[]'::jsonb)
  );
end;
$$;

create function master_memory.export_master_memory_markdown(p_include_highly_sensitive boolean default false)
returns text
language plpgsql
security definer
set search_path = pg_catalog, master_memory, auth
as $$
declare
  v_owner uuid := (select auth.uid());
  v_base text;
  v_projects text;
  v_timeline text;
  v_payments text;
  v_sources text;
begin
  if v_owner is null then raise exception 'authentication required'; end if;
  v_base := master_memory.export_master_memory_v02_markdown(p_include_highly_sensitive);
  select coalesce(string_agg(format('### %s\n- ID: `%s`\n- Type: %s\n- Status: %s\n- Sensitivity: %s\n- Description: %s\n', p.name, p.id, p.project_type, p.status, p.sensitivity, coalesce(p.description, '')), E'\n' order by p.created_at), '_Nessun progetto._') into v_projects from master_memory.projects p where p.owner_id = v_owner and (p_include_highly_sensitive or p.sensitivity <> 'HIGHLY_SENSITIVE');
  select coalesce(string_agg(format('- %s — %s — %s%s', t.occurred_at, t.event_type, coalesce(t.title, ''), case when t.phase is null then '' else ' [' || t.phase || ']' end), E'\n' order by t.occurred_at), '_Nessun evento di timeline._') into v_timeline from master_memory.project_timeline_entries t join master_memory.projects p on p.id = t.project_id where p.owner_id = v_owner and (p_include_highly_sensitive or p.sensitivity <> 'HIGHLY_SENSITIVE');
  select coalesce(string_agg(format('- %s — %s %s — %s', pay.payment_date, pay.amount, pay.currency, pay.description), E'\n' order by pay.payment_date), '_Nessun pagamento._') into v_payments from master_memory.project_payments pay left join master_memory.projects p on p.id = pay.project_id where pay.owner_id = v_owner and (p_include_highly_sensitive or (pay.sensitivity <> 'HIGHLY_SENSITIVE' and (p.id is null or p.sensitivity <> 'HIGHLY_SENSITIVE')));
  select coalesce(string_agg(format('- progetto `%s` — source `%s` — ruolo %s', ps.project_id, ps.source_id, ps.source_role), E'\n' order by ps.created_at), '_Nessuna relazione project/source._') into v_sources from master_memory.project_sources ps join master_memory.projects p on p.id = ps.project_id where p.owner_id = v_owner and (p_include_highly_sensitive or p.sensitivity <> 'HIGHLY_SENSITIVE');
  return v_base || E'\n\n## Projects\n\n' || v_projects || E'\n\n## Project timeline\n\n' || v_timeline || E'\n\n## Payments\n\n' || v_payments || E'\n\n## Project sources\n\n' || v_sources || E'\n';
end;
$$;

alter table master_memory.projects enable row level security;
alter table master_memory.projects force row level security;
alter table master_memory.project_status_history enable row level security;
alter table master_memory.project_status_history force row level security;
alter table master_memory.project_payments enable row level security;
alter table master_memory.project_payments force row level security;
alter table master_memory.project_timeline_entries enable row level security;
alter table master_memory.project_timeline_entries force row level security;
alter table master_memory.journal_payment_links enable row level security;
alter table master_memory.journal_payment_links force row level security;
alter table master_memory.project_sources enable row level security;
alter table master_memory.project_sources force row level security;

create policy projects_select_own on master_memory.projects for select to authenticated using (owner_id = (select auth.uid()));
create policy project_status_history_select_own on master_memory.project_status_history for select to authenticated using (exists (select 1 from master_memory.projects p where p.id = project_id and p.owner_id = (select auth.uid())));
create policy project_payments_select_own on master_memory.project_payments for select to authenticated using (owner_id = (select auth.uid()));
create policy project_timeline_entries_select_own on master_memory.project_timeline_entries for select to authenticated using (owner_id = (select auth.uid()));
create policy journal_payment_links_select_own on master_memory.journal_payment_links for select to authenticated using (exists (select 1 from master_memory.journal_entries je where je.id = journal_entry_id and je.owner_id = (select auth.uid())));
create policy project_sources_select_own on master_memory.project_sources for select to authenticated using (exists (select 1 from master_memory.projects p where p.id = project_id and p.owner_id = (select auth.uid())));

revoke all on table master_memory.projects, master_memory.project_status_history, master_memory.project_payments, master_memory.project_timeline_entries, master_memory.journal_payment_links, master_memory.project_sources from public, anon, authenticated;
revoke all on function master_memory.export_master_memory_v02_json(boolean) from public, anon, authenticated;
revoke all on function master_memory.export_master_memory_v02_markdown(boolean) from public, anon, authenticated;
revoke all on function master_memory.create_project(text, text, text, master_memory.project_status, master_memory.sensitivity_level, date, date, jsonb) from public, anon, authenticated;
revoke all on function master_memory.transition_project_status(uuid, master_memory.project_status, text, uuid, jsonb) from public, anon, authenticated;
revoke all on function master_memory.create_project_payment(date, numeric, text, text, text, uuid, uuid, text, master_memory.sensitivity_level, jsonb) from public, anon, authenticated;
revoke all on function master_memory.add_project_timeline_entry(uuid, timestamptz, master_memory.project_timeline_event_type, text, text, master_memory.project_phase, uuid, uuid, uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function master_memory.link_journal_payment(uuid, uuid, master_memory.project_payment_link_type) from public, anon, authenticated;
revoke all on function master_memory.link_project_source(uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function master_memory.export_master_memory_json(boolean) from public, anon, authenticated;
revoke all on function master_memory.export_master_memory_markdown(boolean) from public, anon, authenticated;

grant execute on function master_memory.create_project(text, text, text, master_memory.project_status, master_memory.sensitivity_level, date, date, jsonb) to authenticated;
grant execute on function master_memory.transition_project_status(uuid, master_memory.project_status, text, uuid, jsonb) to authenticated;
grant execute on function master_memory.create_project_payment(date, numeric, text, text, text, uuid, uuid, text, master_memory.sensitivity_level, jsonb) to authenticated;
grant execute on function master_memory.add_project_timeline_entry(uuid, timestamptz, master_memory.project_timeline_event_type, text, text, master_memory.project_phase, uuid, uuid, uuid, uuid, text, jsonb) to authenticated;
grant execute on function master_memory.link_journal_payment(uuid, uuid, master_memory.project_payment_link_type) to authenticated;
grant execute on function master_memory.link_project_source(uuid, uuid, text, jsonb) to authenticated;
grant execute on function master_memory.export_master_memory_json(boolean) to authenticated;
grant execute on function master_memory.export_master_memory_markdown(boolean) to authenticated;

commit;
