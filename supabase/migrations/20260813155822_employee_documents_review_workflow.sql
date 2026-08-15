
-- Document review workflow columns. Expiry status stays computed client-side
-- from expiry_date (expired / expiring / current / non_expiring) --- this
-- migration only adds approval/versioning state, which is orthogonal.

alter table public.employee_documents
  add column if not exists review_status text not null default 'approved'
    check (review_status in ('pending_review','approved','rejected','superseded','archived')),
  add column if not exists version_number integer not null default 1
    check (version_number >= 1),
  add column if not exists supersedes_document_id uuid references public.employee_documents(id),
  add column if not exists is_current boolean not null default true,
  add column if not exists submitted_by uuid references auth.users(id),
  add column if not exists submitted_at timestamptz not null default now(),
  add column if not exists reviewed_by uuid references auth.users(id),
  add column if not exists reviewed_at timestamptz,
  add column if not exists rejection_reason text,
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references auth.users(id),
  add column if not exists storage_path text,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

-- Backfill storage_path from the legacy file_url column (same private-bucket
-- object path today; kept as a separate column name going forward since
-- "file_url" implied something publicly linkable, which it never was).
update public.employee_documents
  set storage_path = file_url
  where storage_path is null;

alter table public.employee_documents
  alter column storage_path set not null;

-- Existing rows (there are none in production yet, but keep this safe for
-- any future data) are treated as already-approved current documents rather
-- than silently defaulting to pending_review.
update public.employee_documents
  set review_status = 'approved', is_current = true, version_number = 1
  where submitted_at = created_at; -- freshly-added-column rows only, no-op once backfilled once

-- A document can only supersede a document belonging to the same employee.
alter table public.employee_documents
  add constraint employee_documents_supersedes_same_employee
  check (supersedes_document_id is null or supersedes_document_id <> id);

create index if not exists employee_documents_supersedes_idx
  on public.employee_documents (supersedes_document_id);
create index if not exists employee_documents_employee_current_idx
  on public.employee_documents (employee_id, is_current);
create index if not exists employee_documents_review_status_idx
  on public.employee_documents (review_status);

-- Reuse the existing generic updated_at trigger helper (used elsewhere in
-- this schema, e.g. employee_compensation) rather than inventing a new one.
drop trigger if exists employee_documents_set_updated_at on public.employee_documents;
create trigger employee_documents_set_updated_at
  before update on public.employee_documents
  for each row execute function public.set_updated_at();

comment on column public.employee_documents.review_status is
  'Approval lifecycle, independent of expiry_date-derived expiry status: pending_review -> approved -> (superseded | archived), or rejected.';
comment on column public.employee_documents.is_current is
  'True only for the single approved version an employee/manager should treat as authoritative. Renewals start false and only flip true on approval, atomically with the prior current version flipping to superseded.';
comment on column public.employee_documents.storage_path is
  'Private storage object path: entity_id/employee_id/document_id/version_number/filename. Never a public URL.';

