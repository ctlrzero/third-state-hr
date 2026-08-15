
-- Recruitment & Hiring Pipeline (Third State Café HR System Design v1.1, Sections 4.20-4.25 / 5.11 / 7.13)
-- Follows this project's existing conventions: my_role()/my_entity()/my_location() RLS helpers,
-- flat entity_id/location_id columns for RLS-ability, set_updated_at trigger, audit_log pattern.

create table public.job_requisitions (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id),
  location_id uuid not null references public.locations(id),
  position_id uuid not null references public.positions(id),
  headcount int not null default 1 check (headcount >= 1),
  status text not null default 'draft'
    check (status in ('draft','open','on_hold','closed','cancelled')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  opened_by uuid references auth.users(id),
  opened_at timestamptz,
  closed_by uuid references auth.users(id),
  closed_at timestamptz
);
comment on table public.job_requisitions is 'BR-REC-001: bound to one entity/location for its lifetime.';

create table public.candidates (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id),
  location_id uuid references public.locations(id),
  full_name text not null,
  contact_email text,
  contact_phone text,
  source text not null default 'other'
    check (source in ('referral','walk_in','online','agency','other')),
  resume_url text,
  status text not null default 'new'
    check (status in ('new','screening','interviewing','offer','hired','rejected','withdrawn')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.candidates is 'BR-REC-002: resume_url is a private storage path, never a public URL.';

create table public.job_applications (
  id uuid primary key default gen_random_uuid(),
  requisition_id uuid not null references public.job_requisitions(id),
  candidate_id uuid not null references public.candidates(id),
  applied_at timestamptz not null default now(),
  stage text not null default 'applied'
    check (stage in ('applied','screening','interviewing','offer','hired','rejected','withdrawn')),
  rejection_reason text,
  check (stage <> 'rejected' or rejection_reason is not null),
  unique (requisition_id, candidate_id)
);

create table public.interview_stages (
  id uuid primary key default gen_random_uuid(),
  requisition_id uuid not null references public.job_requisitions(id),
  sequence int not null check (sequence >= 1),
  name text not null,
  unique (requisition_id, sequence)
);

create table public.interviews (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.job_applications(id),
  stage_id uuid not null references public.interview_stages(id),
  scheduled_at timestamptz not null,
  interviewer_id uuid not null references auth.users(id),
  outcome text not null default 'pending'
    check (outcome in ('pending','pass','fail')),
  notes text,
  recorded_by uuid references auth.users(id),
  recorded_at timestamptz
);
comment on table public.interviews is 'BR-REC-003: notes never capture compensation discussion.';

create table public.offers (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null unique references public.job_applications(id),
  position_id uuid not null references public.positions(id),
  proposed_salary_amount numeric not null check (proposed_salary_amount >= 0),
  proposed_start_date date not null,
  status text not null default 'draft'
    check (status in ('draft','sent','accepted','declined','rescinded')),
  sent_by uuid references auth.users(id),
  sent_at timestamptz,
  decided_at timestamptz,
  decision_reason text,
  check (status not in ('declined','rescinded') or decision_reason is not null),
  converted_employee_id uuid unique references public.employees(id),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.offers is
  'BR-REC-004: proposed_salary_amount is owner/entity_admin only at the RLS layer -- '
  'the walled-garden pattern used for employee_compensation/payslips extends here; '
  'location_manager has zero access to this table.';

-- updated_at triggers (matches existing convention on employees/employee_compensation/etc.)
create trigger trg_candidates_updated_at before update on public.candidates
  for each row execute function public.set_updated_at();
create trigger trg_offers_updated_at before update on public.offers
  for each row execute function public.set_updated_at();

-- audit trigger for the one sensitive table in this module (matches trg_employees_audit)
create or replace function public.log_offer_changes()
returns trigger
language plpgsql
security definer
as $$
begin
  if tg_op = 'UPDATE' then
    insert into audit_log(table_name, record_id, changed_by, action, old_value, new_value)
    values ('offers', new.id, auth.uid(), 'update', to_jsonb(old), to_jsonb(new));
  elsif tg_op = 'INSERT' then
    insert into audit_log(table_name, record_id, changed_by, action, new_value)
    values ('offers', new.id, auth.uid(), 'insert', to_jsonb(new));
  end if;
  return new;
end;
$$;

create trigger trg_offers_audit after insert or update on public.offers
  for each row execute function public.log_offer_changes();

-- Row Level Security
alter table public.job_requisitions enable row level security;
alter table public.candidates enable row level security;
alter table public.job_applications enable row level security;
alter table public.interview_stages enable row level security;
alter table public.interviews enable row level security;
alter table public.offers enable row level security;

create policy requisitions_select on public.job_requisitions for select using (
  (my_role() = 'owner')
  or (my_role() = 'entity_admin' and entity_id = my_entity())
  or (my_role() = 'location_manager' and location_id = my_location())
);
create policy requisitions_modify on public.job_requisitions for all using (
  (my_role() = 'owner')
  or (my_role() = 'entity_admin' and entity_id = my_entity())
  or (my_role() = 'location_manager' and location_id = my_location())
) with check (
  (my_role() = 'owner')
  or (my_role() = 'entity_admin' and entity_id = my_entity())
  or (my_role() = 'location_manager' and location_id = my_location())
);

create policy candidates_access on public.candidates for all using (
  (my_role() = 'owner')
  or (my_role() = 'entity_admin' and entity_id = my_entity())
  or (my_role() = 'location_manager' and location_id = my_location())
) with check (
  (my_role() = 'owner')
  or (my_role() = 'entity_admin' and entity_id = my_entity())
  or (my_role() = 'location_manager' and location_id = my_location())
);

create policy applications_access on public.job_applications for all using (
  exists (
    select 1 from public.job_requisitions jr
    where jr.id = job_applications.requisition_id
      and (
        (my_role() = 'owner')
        or (my_role() = 'entity_admin' and jr.entity_id = my_entity())
        or (my_role() = 'location_manager' and jr.location_id = my_location())
      )
  )
) with check (
  exists (
    select 1 from public.job_requisitions jr
    where jr.id = job_applications.requisition_id
      and (
        (my_role() = 'owner')
        or (my_role() = 'entity_admin' and jr.entity_id = my_entity())
        or (my_role() = 'location_manager' and jr.location_id = my_location())
      )
  )
);

create policy interview_stages_access on public.interview_stages for all using (
  exists (
    select 1 from public.job_requisitions jr
    where jr.id = interview_stages.requisition_id
      and (
        (my_role() = 'owner')
        or (my_role() = 'entity_admin' and jr.entity_id = my_entity())
        or (my_role() = 'location_manager' and jr.location_id = my_location())
      )
  )
) with check (
  exists (
    select 1 from public.job_requisitions jr
    where jr.id = interview_stages.requisition_id
      and (
        (my_role() = 'owner')
        or (my_role() = 'entity_admin' and jr.entity_id = my_entity())
        or (my_role() = 'location_manager' and jr.location_id = my_location())
      )
  )
);

-- Interviews: assigned interviewer (any role) can see/record their own interview; otherwise scoped like applications.
create policy interviews_access on public.interviews for all using (
  interviewer_id = auth.uid()
  or exists (
    select 1 from public.job_applications ja
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = interviews.application_id
      and (
        (my_role() = 'owner')
        or (my_role() = 'entity_admin' and jr.entity_id = my_entity())
        or (my_role() = 'location_manager' and jr.location_id = my_location())
      )
  )
) with check (
  interviewer_id = auth.uid()
  or exists (
    select 1 from public.job_applications ja
    join public.job_requisitions jr on jr.id = ja.requisition_id
    where ja.id = interviews.application_id
      and (
        (my_role() = 'owner')
        or (my_role() = 'entity_admin' and jr.entity_id = my_entity())
        or (my_role() = 'location_manager' and jr.location_id = my_location())
      )
  )
);

-- Offers: payroll-walled. owner/entity_admin only -- no location_manager branch at all.
create policy offers_access on public.offers for all using (
  (my_role() = 'owner')
  or (
    my_role() = 'entity_admin' and exists (
      select 1 from public.job_applications ja
      join public.job_requisitions jr on jr.id = ja.requisition_id
      where ja.id = offers.application_id and jr.entity_id = my_entity()
    )
  )
) with check (
  (my_role() = 'owner')
  or (
    my_role() = 'entity_admin' and exists (
      select 1 from public.job_applications ja
      join public.job_requisitions jr on jr.id = ja.requisition_id
      where ja.id = offers.application_id and jr.entity_id = my_entity()
    )
  )
);

-- Cross-table conversion (BR-REC-004/005): mirrors approve_leave_request()'s style --
-- manual authorization check, raises on violation, atomic side effects.
create or replace function public.convert_offer_to_employee(p_offer_id uuid)
returns uuid
language plpgsql
security definer
as $$
declare
  v_entity_id uuid;
  v_location_id uuid;
  v_position_id uuid;
  v_candidate_id uuid;
  v_full_name text;
  v_email text;
  v_phone text;
  v_start_date date;
  v_status text;
  v_converted uuid;
  v_application_id uuid;
  v_new_employee_id uuid;
begin
  select jr.entity_id, jr.location_id, o.position_id, c.id, c.full_name, c.contact_email, c.contact_phone,
         o.proposed_start_date, o.status, o.converted_employee_id, o.application_id
    into v_entity_id, v_location_id, v_position_id, v_candidate_id, v_full_name, v_email, v_phone,
         v_start_date, v_status, v_converted, v_application_id
  from public.offers o
  join public.job_applications ja on ja.id = o.application_id
  join public.job_requisitions jr on jr.id = ja.requisition_id
  join public.candidates c on c.id = ja.candidate_id
  where o.id = p_offer_id;

  if v_entity_id is null then
    raise exception 'Offer % not found', p_offer_id;
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
  ) then
    raise exception 'Not authorized to convert this offer';
  end if;

  if v_status <> 'accepted' then
    raise exception 'Offer must be Accepted before conversion (current status: %)', v_status;
  end if;

  if v_converted is not null then
    raise exception 'Offer has already been converted to employee %', v_converted;
  end if;

  -- Draft employee -- still passes the full FN-02 completeness/activation gate (HR-P02/HR-P13);
  -- payroll fields are NOT carried over here and must be entered separately (payroll walled garden).
  insert into public.employees (entity_id, home_location_id, position_id, full_name, email, phone,
                                 employment_status, join_date)
  values (v_entity_id, v_location_id, v_position_id, v_full_name, v_email, v_phone,
          'pre_boarding', v_start_date)
  returning id into v_new_employee_id;

  update public.offers set converted_employee_id = v_new_employee_id where id = p_offer_id;
  update public.job_applications set stage = 'hired' where id = v_application_id;
  update public.candidates set status = 'hired' where id = v_candidate_id;

  return v_new_employee_id;
end;
$$;

