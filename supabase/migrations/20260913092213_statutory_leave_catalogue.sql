
-- ============================================================
-- BR-LVE-006 / BR-LVE-007 / D03: statutory leave catalogue.
-- Adds metadata for pay-tier structure, event-based (vs. continuously
-- available) entitlements, and gender eligibility -- then corrects the
-- auto-seed triggers to respect them before any statutory types are
-- inserted. All figures sourced from Federal Decree-Law No. 33 of 2021
-- (UAE Labour Law) via u.ae -- flagged is_approved = false / noted as
-- pending HR-Legal validation per BRD Decision D03, same gate pattern
-- already used for leave_accrual_policies.
-- ============================================================

alter table public.leave_types
  add column is_event_based boolean not null default false,
  add column eligible_gender text check (eligible_gender in ('female','male') or eligible_gender is null),
  add column full_pay_days numeric,
  add column half_pay_days numeric,
  add column unpaid_days numeric,
  add column eligibility_notes text,
  add column statutory_reference text;

comment on column public.leave_types.is_event_based is
  'True for entitlements granted per qualifying event (maternity, parental, bereavement, Hajj) rather than continuously available/accruing. Event-based types seed at 0 balance; use grant_leave_balance() to credit once eligibility is confirmed.';
comment on column public.leave_types.eligible_gender is
  'Restricts auto-seeding to one gender (e.g. Maternity Leave = female). Null = no restriction. Employees with unset/unknown gender are never auto-seeded for a gender-restricted type.';

-- ------------------------------------------------------------
-- Corrected auto-seed logic: event-based types seed at 0 (not the
-- full statutory ceiling), and gender-restricted types skip employees
-- whose gender doesn't match or is unset.
-- ------------------------------------------------------------

create or replace function public.seed_leave_balances_for_employee()
returns trigger
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  insert into leave_balances (employee_id, leave_type_id, balance_days)
  select new.id, lt.id, case when lt.is_event_based then 0 else lt.accrual_days_per_year end
  from leave_types lt
  where lt.entity_id = new.entity_id
    and (lt.eligible_gender is null or lt.eligible_gender = new.gender)
  on conflict (employee_id, leave_type_id) do nothing;
  return new;
end;
$$;

create or replace function public.seed_leave_balances_for_leave_type()
returns trigger
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  insert into leave_balances (employee_id, leave_type_id, balance_days)
  select e.id, new.id, case when new.is_event_based then 0 else new.accrual_days_per_year end
  from employees e
  where e.entity_id = new.entity_id
    and (new.eligible_gender is null or new.eligible_gender = e.gender)
  on conflict (employee_id, leave_type_id) do nothing;
  return new;
end;
$$;

-- ------------------------------------------------------------
-- Manual grant for event-based entitlements (owner/entity_admin only,
-- entity-scoped, audited). This is how Maternity/Parental/Bereavement/
-- Hajj balances get credited once HR confirms eligibility for a
-- specific case -- deliberately not automatic.
-- ------------------------------------------------------------

create or replace function public.grant_leave_balance(
  p_employee_id uuid,
  p_leave_type_id uuid,
  p_days numeric,
  p_reason text
) returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_entity uuid;
  v_lt_entity uuid;
  v_before numeric;
  v_after numeric;
begin
  select entity_id into v_entity from employees where id = p_employee_id;
  select entity_id into v_lt_entity from leave_types where id = p_leave_type_id;

  if v_entity is null or v_lt_entity is null or v_entity <> v_lt_entity then
    raise exception 'Employee and leave type must belong to the same entity';
  end if;
  if not (my_role() = 'owner' or (my_role() = 'entity_admin' and v_entity = my_entity())) then
    raise exception 'Not authorized to grant leave balance for this entity';
  end if;
  if p_days <= 0 then
    raise exception 'Grant amount must be positive';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A reason is required to grant a leave balance';
  end if;

  insert into leave_balances (employee_id, leave_type_id, balance_days)
  values (p_employee_id, p_leave_type_id, p_days)
  on conflict (employee_id, leave_type_id)
  do update set balance_days = leave_balances.balance_days + excluded.balance_days, updated_at = now()
  returning balance_days - p_days, balance_days into v_before, v_after;

  insert into audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, employee_id)
  values ('leave_balances', p_employee_id, auth.uid(), 'leave_balance_granted',
    jsonb_build_object('balance_days', v_before),
    jsonb_build_object('balance_days', v_after, 'days_granted', p_days, 'reason', p_reason, 'leave_type_id', p_leave_type_id),
    v_entity, p_employee_id);
end;
$$;

-- ------------------------------------------------------------
-- Seed the statutory catalogue for the two REAL entities only.
-- UAT Entity A/B are deliberately left with their simplified 21/10-day
-- test fixtures -- not touched.
-- ------------------------------------------------------------

insert into public.leave_types (entity_id, name, accrual_days_per_year, requires_approval, is_event_based, eligible_gender, full_pay_days, half_pay_days, unpaid_days, eligibility_notes, statutory_reference)
select e.id, v.name, v.accrual_days_per_year, true, v.is_event_based, v.eligible_gender, v.full_pay_days, v.half_pay_days, v.unpaid_days, v.eligibility_notes, v.statutory_reference
from public.entities e
cross join (values
  ('Annual Leave', 30, false, null, null, null, null,
   'Full 30 days after 1 year of service. Employees with 6-12 months service accrue 2 days/month instead -- not modeled by the current annual-frequency accrual policy; treat sub-1-year balances as a manual HR calculation until a tiered accrual mode is built.',
   'UAE Labour Law Art. 29'),
  ('Sick Leave', 90, false, null, 15, 30, 45,
   'Available after completing probation. Pay splits across the 90 days: first 15 full pay, next 30 half pay, remaining 45 unpaid -- this system tracks the 90-day balance only; apply the pay-tier split manually in payroll (payslip_deductions/manual review), consistent with the no-automatic-deduction principle used elsewhere in this system.',
   'UAE Labour Law Art. 31'),
  ('Maternity Leave', 60, true, 'female', 45, 15, 0,
   'Event-based -- grant via grant_leave_balance() once pregnancy/maternity is confirmed, not auto-available. An additional 45 days unpaid (illness/complications) and a further 30 paid + 30 unpaid (child illness/disability) may apply per case -- grant those as separate manual additions with the specific reason, not as part of the base 60.',
   'UAE Labour Law Art. 30'),
  ('Parental Leave', 5, true, null, 5, null, null,
   'Event-based -- available to both parents, to be taken within 6 months of the child''s birth. Grant via grant_leave_balance() when a birth is confirmed rather than sitting in every employee''s balance by default.',
   'UAE Labour Law Art. 32(1)'),
  ('Bereavement Leave', 5, true, null, 5, null, null,
   'Event-based, tiered by relation: 5 days for a spouse, 3 days for a parent/child/sibling/grandchild/grandparent. This type stores the 5-day ceiling only -- grant the correct tiered amount via grant_leave_balance() with the relation noted in the reason.',
   'UAE Labour Law'),
  ('Study Leave', 10, true, null, 10, null, null,
   'Requires 2 years'' service and enrolment at a UAE-accredited institution. PAID STATUS IS DISPUTED IN SOURCES -- flagged pending HR/Legal confirmation before this is treated as a paid entitlement. Event-based -- grant via grant_leave_balance() once eligibility and paid status are confirmed.',
   'UAE Labour Law -- paid status unconfirmed, HR/Legal review required (BRD D03)'),
  ('Hajj Leave', 30, true, null, null, null, 30,
   'Unpaid, once only during the entire employment relationship. No minimum service period found in current sources -- confirm with HR/Legal before enabling. Event-based -- grant via grant_leave_balance() and do not re-grant for the same employee.',
   'UAE Labour Law (u.ae) -- once per employment'),
  ('Unpaid / Discretionary Leave', 0, true, null, null, null, null,
   'Not a statutory entitlement -- purely employer discretion (e.g. Umrah leave, which UAE law does not regulate). Grant case-by-case via grant_leave_balance() rather than a standing balance.',
   'Employer discretion -- no statutory basis')
) as v(name, accrual_days_per_year, is_event_based, eligible_gender, full_pay_days, half_pay_days, unpaid_days, eligibility_notes, statutory_reference)
where e.name in ('Third State Cafe', 'Ateej Tea Brew')
on conflict do nothing;

-- Accrual policies for the two genuinely periodic types only
-- (Annual, Sick). Both left unapproved -- run_leave_accrual() already
-- hard-blocks on is_approved = false, so nothing runs until an Owner
-- explicitly approves via approve_leave_accrual_policy().
insert into public.leave_accrual_policies (entity_id, leave_type_id, frequency, days_per_period, rounding, max_balance_days, carry_forward_cap_days, probation_days, policy_start_date, is_approved)
select lt.entity_id, lt.id, 'annual', 30, 'none', null, null, 365, current_date, false
from public.leave_types lt
join public.entities e on e.id = lt.entity_id
where e.name in ('Third State Cafe', 'Ateej Tea Brew') and lt.name = 'Annual Leave'
on conflict (leave_type_id) do nothing;

insert into public.leave_accrual_policies (entity_id, leave_type_id, frequency, days_per_period, rounding, max_balance_days, carry_forward_cap_days, probation_days, policy_start_date, is_approved)
select lt.entity_id, lt.id, 'annual', 90, 'none', 90, 0, 180, current_date, false
from public.leave_types lt
join public.entities e on e.id = lt.entity_id
where e.name in ('Third State Cafe', 'Ateej Tea Brew') and lt.name = 'Sick Leave'
on conflict (leave_type_id) do nothing;
