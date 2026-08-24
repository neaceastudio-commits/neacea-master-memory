begin;

create index project_status_history_changed_by_idx
  on master_memory.project_status_history(changed_by);

commit;
