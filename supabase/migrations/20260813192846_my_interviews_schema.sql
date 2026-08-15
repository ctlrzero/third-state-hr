
alter table public.interview_stages add column if not exists guide text;

alter table public.interviews
  add column if not exists format text not null default 'in_person'
    check (format in ('in_person', 'video', 'phone')),
  add column if not exists meeting_location text,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references auth.users(id),
  add column if not exists cancellation_reason text;

alter table public.interviews
  add constraint interviews_cancellation_reason_required
  check (cancelled_at is null or cancellation_reason is not null);

create table public.interview_feedback (
  id uuid primary key default gen_random_uuid(),
  interview_id uuid not null unique references public.interviews(id),
  submitted_by uuid not null references auth.users(id),
  status text not null default 'draft' check (status in ('draft', 'submitted', 'reopened')),
  recommendation text check (recommendation in ('strong_yes', 'yes', 'neutral', 'no', 'strong_no')),
  competency_ratings jsonb,
  strengths text,
  concerns text,
  notes text,
  submitted_at timestamptz,
  reopened_by uuid references auth.users(id),
  reopened_at timestamptz,
  reopen_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint interview_feedback_submitted_requires_recommendation
    check (status <> 'submitted' or recommendation is not null),
  constraint interview_feedback_reopen_requires_reason
    check (reopened_at is null or reopen_reason is not null)
);

create trigger interview_feedback_set_updated_at
  before update on public.interview_feedback
  for each row execute function public.set_updated_at();

alter table public.interview_feedback enable row level security;

create table public.candidate_files (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(id),
  entity_id uuid not null references public.entities(id),
  file_type text not null check (file_type in ('resume', 'interview_pack', 'other')),
  storage_path text not null unique,
  visible_to_interviewers boolean not null default false,
  uploaded_by uuid references auth.users(id),
  uploaded_at timestamptz not null default now()
);

alter table public.candidate_files enable row level security;

create index candidate_files_candidate_id_idx on public.candidate_files (candidate_id);
