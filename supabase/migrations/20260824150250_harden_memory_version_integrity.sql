begin;

-- Cover every foreign key used by the V0.1 relationships and RLS paths.
create index memory_items_owner_id_idx
  on master_memory.memory_items(owner_id);

create index memory_items_current_version_id_idx
  on master_memory.memory_items(current_version_id)
  where current_version_id is not null;

create index memory_versions_supersedes_version_id_idx
  on master_memory.memory_versions(supersedes_version_id)
  where supersedes_version_id is not null;

create index memory_intake_records_source_id_idx
  on master_memory.memory_intake_records(source_id);

create index memory_intake_records_supersedes_id_idx
  on master_memory.memory_intake_records(supersedes_intake_record_id)
  where supersedes_intake_record_id is not null;

-- A current pointer must always reference a version of the same logical memory.
create function master_memory.validate_current_version_pointer()
returns trigger
language plpgsql
set search_path = pg_catalog, master_memory
as $$
declare
  v_version_memory_id uuid;
begin
  if new.current_version_id is null then
    return new;
  end if;

  select memory_id
  into v_version_memory_id
  from master_memory.memory_versions
  where id = new.current_version_id;

  if not found or v_version_memory_id <> new.id then
    raise exception 'current_version_id must belong to its memory item';
  end if;

  return new;
end;
$$;

create trigger memory_items_validate_current_version_pointer
  before insert or update of current_version_id on master_memory.memory_items
  for each row execute function master_memory.validate_current_version_pointer();

-- Version chains stay inside one logical memory and advance one version at a time.
create function master_memory.validate_memory_version_lineage()
returns trigger
language plpgsql
set search_path = pg_catalog, master_memory
as $$
declare
  v_predecessor_memory_id uuid;
  v_predecessor_version integer;
begin
  if new.version = 1 and new.supersedes_version_id is not null then
    raise exception 'version 1 cannot supersede another version';
  end if;

  if new.version > 1 and new.supersedes_version_id is null then
    raise exception 'successor versions must identify the version they supersede';
  end if;

  if new.supersedes_version_id is null then
    return new;
  end if;

  select memory_id, version
  into v_predecessor_memory_id, v_predecessor_version
  from master_memory.memory_versions
  where id = new.supersedes_version_id;

  if not found
    or v_predecessor_memory_id <> new.memory_id
    or v_predecessor_version <> new.version - 1 then
    raise exception 'a version must supersede the immediately previous version of the same memory';
  end if;

  return new;
end;
$$;

create trigger memory_versions_validate_lineage
  before insert on master_memory.memory_versions
  for each row execute function master_memory.validate_memory_version_lineage();

revoke all on function master_memory.validate_current_version_pointer() from public, anon, authenticated;
revoke all on function master_memory.validate_memory_version_lineage() from public, anon, authenticated;

commit;
