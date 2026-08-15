
-- The previous migration's table-level UNIQUE(employee_id, doc_type, is_current)
-- was wrong: it would also cap historical (is_current = false) rows to one
-- per employee/doc_type, breaking version history. Replace it with a partial
-- unique index that only constrains the *current* row.
alter table public.employee_documents
  drop constraint if exists employee_documents_one_current_per_type;

create unique index if not exists employee_documents_one_current_per_type_idx
  on public.employee_documents (employee_id, doc_type)
  where is_current = true;

comment on index public.employee_documents_one_current_per_type_idx is
  'At most one is_current=true row per employee/doc_type. Not deferrable (partial indexes cannot back a deferrable constraint) — approve_document() relies on flipping the old row to is_current=false before flipping the new row to true, in that order, within the same transaction.';

