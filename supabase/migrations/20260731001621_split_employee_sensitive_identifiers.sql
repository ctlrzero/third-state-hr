-- HIGH FIX: employees held bank_iban/bank_name/national_id_no/passport_no/visa_no/
-- labor_card_no/health_card_no on the SAME shared table that location_manager can
-- fully SELECT (row-level RLS only, no column masking). Any location_manager could
-- read a subordinate's bank account and government ID numbers -- the design calls
-- for bank/identity numbers to be structurally owner/entity_admin-only, mirroring
-- the existing employee_compensation pattern.
--
-- Expiry DATES stay on employees (compliance_alerts depends on them and they are
-- far less sensitive than the numbers themselves); the actual document/bank NUMBERS
-- move to a new table with owner/entity_admin-only RLS, matching employee_compensation.

create table public.employee_identity_documents (
  employee_id uuid primary key references public.employees(id) on delete cascade,
  national_id_no text,
  passport_no text,
  visa_no text,
  labor_card_no text,
  health_card_no text,
  bank_name text,
  bank_iban text,
  updated_at timestamptz not null default now()
);

comment on table public.employee_identity_documents is
  'Bank and government-ID numbers, split out of employees so location_manager (row-level RLS only) cannot read them. Owner/entity_admin only -- mirrors employee_compensation.';

insert into public.employee_identity_documents
  (employee_id, national_id_no, passport_no, visa_no, labor_card_no, health_card_no, bank_name, bank_iban, updated_at)
select id, national_id_no, passport_no, visa_no, labor_card_no, health_card_no, bank_name, bank_iban, now()
from public.employees
where national_id_no is not null or passport_no is not null or visa_no is not null
   or labor_card_no is not null or health_card_no is not null or bank_name is not null or bank_iban is not null;

alter table public.employees
  drop column national_id_no,
  drop column passport_no,
  drop column visa_no,
  drop column labor_card_no,
  drop column health_card_no,
  drop column bank_name,
  drop column bank_iban;

alter table public.employee_identity_documents enable row level security;

create policy identity_documents_access
on public.employee_identity_documents
for all
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (
    select 1 from employees e where e.id = employee_identity_documents.employee_id and e.entity_id = my_entity()
  ))
)
with check (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (
    select 1 from employees e where e.id = employee_identity_documents.employee_id and e.entity_id = my_entity()
  ))
);

create trigger trg_identity_documents_set_updated_at
before update on public.employee_identity_documents
for each row execute function public.set_updated_at();

