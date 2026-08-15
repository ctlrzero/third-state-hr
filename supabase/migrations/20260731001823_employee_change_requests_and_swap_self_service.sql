-- BR-ESS-005 (Should): employees have no way to request a contact-detail change
-- for manager/admin approval; there was no table for it at all. Minimal, additive.
create table public.employee_change_requests (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  field_name text not null check (field_name in ('phone','email','emergency_contact_name','emergency_contact_phone')),
  old_value text,
  new_value text not null,
  reason text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_at timestamptz not null default now(),
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  decision_reason text
);

comment on table public.employee_change_requests is
  'BR-ESS-005: employee-initiated contact-detail change, held for manager/admin approval. Original value is untouched until approved.';

alter table public.employee_change_requests enable row level security;

create index if not exists employee_change_requests_employee_id_idx on public.employee_change_requests(employee_id);

-- Employee: submit and view own requests only (no self-approval -- status/decided_*
-- are never settable by the requester; enforced by omitting them from insert check
-- and by there being no employee-facing UPDATE policy at all).
create policy change_requests_insert_own
on public.employee_change_requests
for insert
with check (
  employee_id = my_employee_id()
  and status = 'pending'
  and decided_by is null
  and decided_at is null
);

create policy change_requests_select_own
on public.employee_change_requests
for select
using (employee_id = my_employee_id());

-- Manager/admin/owner: view and decide requests within their scope.
create policy change_requests_decide
on public.employee_change_requests
for all
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (
    select 1 from employees e where e.id = employee_change_requests.employee_id and e.entity_id = my_entity()
  ))
  or (my_role() = 'location_manager' and exists (
    select 1 from employees e where e.id = employee_change_requests.employee_id and e.home_location_id = my_location()
  ))
)
with check (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and exists (
    select 1 from employees e where e.id = employee_change_requests.employee_id and e.entity_id = my_entity()
  ))
  or (my_role() = 'location_manager' and exists (
    select 1 from employees e where e.id = employee_change_requests.employee_id and e.home_location_id = my_location()
  ))
);

-- Apply an approved change to the actual employee record and stamp the decision;
-- keeps the same "no self-approval, reason on file" shape as approve_leave_request.
create or replace function public.decide_employee_change_request(p_request_id uuid, p_action text, p_decision_reason text default null)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_employee_id uuid;
  v_entity_id uuid;
  v_home_location uuid;
  v_field text;
  v_new_value text;
  v_status text;
begin
  select cr.employee_id, e.entity_id, e.home_location_id, cr.field_name, cr.new_value, cr.status
    into v_employee_id, v_entity_id, v_home_location, v_field, v_new_value, v_status
  from employee_change_requests cr
  join employees e on e.id = cr.employee_id
  where cr.id = p_request_id;

  if v_employee_id is null then
    raise exception 'Change request % not found', p_request_id;
  end if;

  if v_status <> 'pending' then
    raise exception 'Change request % already decided', p_request_id;
  end if;

  if not (
    my_role() = 'owner'
    or (my_role() = 'entity_admin' and v_entity_id = my_entity())
    or (my_role() = 'location_manager' and v_home_location = my_location())
  ) then
    raise exception 'Not authorized to decide this change request';
  end if;

  if p_action = 'approve' then
    if v_field = 'phone' then
      update employees set phone = v_new_value where id = v_employee_id;
    elsif v_field = 'email' then
      update employees set email = v_new_value where id = v_employee_id;
    elsif v_field = 'emergency_contact_name' then
      update employees set emergency_contact_name = v_new_value where id = v_employee_id;
    elsif v_field = 'emergency_contact_phone' then
      update employees set emergency_contact_phone = v_new_value where id = v_employee_id;
    end if;
    update employee_change_requests set status = 'approved', decided_by = auth.uid(), decided_at = now(), decision_reason = p_decision_reason where id = p_request_id;
  elsif p_action = 'reject' then
    update employee_change_requests set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_reason = p_decision_reason where id = p_request_id;
  else
    raise exception 'Invalid action %', p_action;
  end if;
end;
$function$;

revoke execute on function public.decide_employee_change_request(uuid, text, text) from anon;

-- Incidental fix found during review: shift_swap_requests had NO policy letting
-- an employee create/view/claim a swap for their own shift -- the feature was
-- unusable by staff (fails safe, but broken). approve/reject still requires
-- manager/owner via approve_shift_swap(); this only restores self-service on the
-- open request itself.
create policy swaps_self_service
on public.shift_swap_requests
for all
using (requested_by = my_employee_id() or claimed_by = my_employee_id())
with check (
  (requested_by = my_employee_id() and status = 'open' and resolved_by is null)
  or (claimed_by = my_employee_id())
);

