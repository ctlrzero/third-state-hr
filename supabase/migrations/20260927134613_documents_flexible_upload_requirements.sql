
-- 1. New table: one row per required document type per employee, independent of
--    whether a file has been uploaded yet. Powers the "Missing / Pending Upload"
--    checklist state on both the employee side and the HR/Manager side.
create table if not exists public.employee_document_requirements (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  doc_type public.document_type not null,
  status text not null default 'missing'
    check (status in ('missing','pending_review','approved','rejected','expiring','archived','waived')),
  document_id uuid references public.employee_documents(id),
  waived_by uuid references auth.users(id),
  waived_reason text,
  waived_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (employee_id, doc_type)
);

create index if not exists employee_document_requirements_employee_idx
  on public.employee_document_requirements (employee_id);
create index if not exists employee_document_requirements_status_idx
  on public.employee_document_requirements (status);

create or replace function public.touch_edr_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_edr_touch_updated_at on public.employee_document_requirements;
create trigger trg_edr_touch_updated_at
  before update on public.employee_document_requirements
  for each row execute function public.touch_edr_updated_at();

alter table public.employee_document_requirements enable row level security;

drop policy if exists edr_select on public.employee_document_requirements;
create policy edr_select on public.employee_document_requirements for select
using (
  exists (
    select 1 from public.employees e where e.id = employee_document_requirements.employee_id
      and (
        e.id = public.my_employee_id()
        or public.my_role() = 'owner'
        or (public.my_role() = 'entity_admin' and e.entity_id = public.my_entity())
        or (public.my_role() = 'location_manager' and e.home_location_id = public.my_location()
            and not public.is_restricted_doc_type(employee_document_requirements.doc_type))
      )
  )
);

drop policy if exists edr_insert on public.employee_document_requirements;
create policy edr_insert on public.employee_document_requirements for insert
with check (
  exists (
    select 1 from public.employees e where e.id = employee_document_requirements.employee_id
      and (
        e.id = public.my_employee_id()
        or public.my_role() = 'owner'
        or (public.my_role() = 'entity_admin' and e.entity_id = public.my_entity())
        or (public.my_role() = 'location_manager' and e.home_location_id = public.my_location()
            and not public.is_restricted_doc_type(employee_document_requirements.doc_type))
      )
  )
);

drop policy if exists edr_update on public.employee_document_requirements;
create policy edr_update on public.employee_document_requirements for update
using (
  exists (
    select 1 from public.employees e where e.id = employee_document_requirements.employee_id
      and (
        e.id = public.my_employee_id()
        or public.my_role() = 'owner'
        or (public.my_role() = 'entity_admin' and e.entity_id = public.my_entity())
        or (public.my_role() = 'location_manager' and e.home_location_id = public.my_location()
            and not public.is_restricted_doc_type(employee_document_requirements.doc_type))
      )
  )
)
with check (
  exists (
    select 1 from public.employees e where e.id = employee_document_requirements.employee_id
      and (
        e.id = public.my_employee_id()
        or public.my_role() = 'owner'
        or (public.my_role() = 'entity_admin' and e.entity_id = public.my_entity())
        or (public.my_role() = 'location_manager' and e.home_location_id = public.my_location()
            and not public.is_restricted_doc_type(employee_document_requirements.doc_type))
      )
  )
);

-- 2. New column on employee_documents: was this the employee's own upload, or did
--    an authorised Manager/Admin stage it on the employee's behalf? Drives both the
--    UI ("uploaded by HR") and the reviewer guard below. `uploaded_by` (existing,
--    previously unused) now records the actor; upload_method records which kind.
alter table public.employee_documents
  add column if not exists upload_method text
  check (upload_method in ('self','assisted'));

-- Backfill: every existing row was self-service (assisted upload did not exist as a
-- concept before this migration), and uploaded_by mirrors submitted_by for consistency.
update public.employee_documents
  set upload_method = coalesce(upload_method, 'self'),
      uploaded_by = coalesce(uploaded_by, submitted_by)
  where upload_method is null or uploaded_by is null;

alter table public.employee_documents
  alter column upload_method set default 'self';
;
