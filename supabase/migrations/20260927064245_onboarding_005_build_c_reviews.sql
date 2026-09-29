create or replace function public.review_onboarding_section(p_instance_id uuid, p_section text, p_decision text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  s public.onboarding_section_submissions;
  v_role text;
  v_review uuid;
begin
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.id is null then raise exception 'Onboarding not found' using errcode = 'P0002'; end if;
  if p_decision not in ('approved', 'changes_required', 'rejected') then
    raise exception 'Decision must be approved, changes_required or rejected' using errcode = '22023';
  end if;
  if p_decision <> 'approved' and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Tell the employee what to change' using errcode = '22023';
  end if;
  select * into s from public.onboarding_section_submissions where instance_id = i.id and section = p_section
   order by version desc limit 1 for update;
  if s.id is null or s.status <> 'submitted' then
    raise exception 'Nothing in this section is waiting for review' using errcode = '22023';
  end if;
  select t.reviewer_role into v_role from public.onboarding_tasks t
   where t.instance_id = i.id and t.section = p_section and t.status = 'submitted' and t.reviewer_role is not null
     and public._onb_can_review(i.id, t.reviewer_role) limit 1;
  if v_role is null then raise exception 'You cannot review this section' using errcode = '42501'; end if;
  if s.submitted_by = auth.uid() and public.my_role() <> 'owner' then
    raise exception 'You submitted this section; someone else must review it' using errcode = '42501';
  end if;

  update public.onboarding_section_submissions set status = p_decision where id = s.id;
  update public.onboarding_tasks
     set status = case when p_decision = 'approved' then 'approved' else 'changes_required' end,
         reviewed_by = auth.uid(), reviewed_at = now(), review_reason = nullif(btrim(coalesce(p_reason, '')), ''), updated_at = now()
   where instance_id = i.id and section = p_section and status = 'submitted' and kind in ('manual', 'profile');
  insert into public.onboarding_reviews (instance_id, section, submission_id, reviewer_id, reviewer_role, decision, reason, before_state)
  values (i.id, p_section, s.id, auth.uid(), v_role, p_decision, nullif(btrim(coalesce(p_reason, '')), ''), s.snapshot)
  returning id into v_review;
  perform public._onb_audit(i.id, 'onboarding_reviews', v_review,
    case when p_decision = 'approved' then 'onboarding_section_approved' else 'onboarding_changes_required' end,
    null, jsonb_build_object('section', p_section, 'version', s.version, 'reason', p_reason));
  if p_decision <> 'approved' then
    perform public.create_notification(i.entity_id, null, i.employee_id, 'onboarding_changes_required',
      'Changes needed on your onboarding', coalesce(p_reason, 'Please review and resubmit.'), 'onboarding_instance', i.id, 'high',
      format('onb:%s:changes:%s:%s', i.id, p_section, s.version));
  end if;
  perform public._onb_touch(i.id);
  return coalesce(public._onb_recompute(i.id), public._onb_readiness(i.id, 'full'));
end;
$$;

create or replace function public.review_onboarding_task(p_task_id uuid, p_decision text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare t public.onboarding_tasks; v_review uuid;
begin
  select * into t from public.onboarding_tasks where id = p_task_id for update;
  if t.id is null then raise exception 'Task not found' using errcode = 'P0002'; end if;
  if t.status <> 'submitted' or t.kind not in ('manual', 'profile') then
    raise exception 'This task is not waiting for review here' using errcode = '22023';
  end if;
  if p_decision not in ('approved', 'changes_required') then raise exception 'Decision must be approved or changes_required' using errcode = '22023'; end if;
  if p_decision = 'changes_required' and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required' using errcode = '22023';
  end if;
  if not public._onb_can_review(t.instance_id, t.reviewer_role) then raise exception 'You cannot review this task' using errcode = '42501'; end if;
  if t.submitted_by = auth.uid() and public.my_role() <> 'owner' then
    raise exception 'You completed this task; someone else must review it' using errcode = '42501';
  end if;
  update public.onboarding_tasks set status = p_decision, reviewed_by = auth.uid(), reviewed_at = now(),
         review_reason = nullif(btrim(coalesce(p_reason, '')), ''), updated_at = now() where id = t.id;
  insert into public.onboarding_reviews (instance_id, section, task_id, reviewer_id, reviewer_role, decision, reason, before_state)
  values (t.instance_id, t.section, t.id, auth.uid(), t.reviewer_role, p_decision, nullif(btrim(coalesce(p_reason, '')), ''), t.evidence)
  returning id into v_review;
  perform public._onb_audit(t.instance_id, 'onboarding_tasks', t.id, 'onboarding_task_reviewed', jsonb_build_object('status', t.status),
    jsonb_build_object('status', p_decision, 'reason', p_reason));
  perform public._onb_touch(t.instance_id);
  perform public._onb_recompute(t.instance_id);
  return jsonb_build_object('ok', true, 'status', p_decision);
end;
$$;

create or replace function public.waive_onboarding_task(p_task_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare t public.onboarding_tasks;
begin
  select * into t from public.onboarding_tasks where id = p_task_id for update;
  if t.id is null then raise exception 'Task not found' using errcode = 'P0002'; end if;
  perform public._onb_require(t.instance_id, 'manage');
  if t.is_statutory or not t.is_waivable then raise exception 'This item is required by law or policy and cannot be waived' using errcode = '22023'; end if;
  if t.kind in ('compensation', 'contract_acceptance') then raise exception 'Pay and contract acceptance cannot be waived' using errcode = '22023'; end if;
  if t.kind = 'document' and t.doc_type in ('passport', 'visa', 'emirates_id', 'contract') then
    raise exception 'Key documents cannot be waived' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if t.status in ('approved', 'waived', 'cancelled') then return jsonb_build_object('ok', true, 'already', true); end if;
  update public.onboarding_tasks set status = 'waived', waived_by = auth.uid(), waived_at = now(), waived_reason = btrim(p_reason),
         updated_at = now() where id = t.id;
  perform public._onb_audit(t.instance_id, 'onboarding_tasks', t.id, 'onboarding_task_waived', jsonb_build_object('status', t.status),
    jsonb_build_object('reason', p_reason));
  perform public._onb_touch(t.instance_id);
  perform public._onb_recompute(t.instance_id);
  return jsonb_build_object('ok', true, 'already', false);
end;
$$;

create or replace function public.set_onboarding_pending_compensation(p_instance_id uuid, p_effective_from date, p_pay_type text,
  p_basic_monthly numeric, p_hourly_rate numeric, p_overtime_eligible boolean, p_reason text, p_variance_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  i public.onboarding_instances;
  v_old public.onboarding_pending_compensation;
  v_offer numeric;
  v_amount numeric := case when p_pay_type = 'monthly' then p_basic_monthly else p_hourly_rate end;
begin
  select * into i from public.onboarding_instances where id = p_instance_id for update;
  if i.id is null then raise exception 'Onboarding not found' using errcode = 'P0002'; end if;
  if not (public._onb_can(i.id, 'manage') or public._onb_can(i.id, 'payroll')) then
    raise exception 'You cannot set pay for this onboarding' using errcode = '42501';
  end if;
  if public.payroll_employee_entity(i.employee_id) is null or public._payroll_can_edit_pay(i.employee_id) is not null then
    raise exception '%', coalesce(public._payroll_can_edit_pay(i.employee_id), 'No permission to change pay') using errcode = '42501';
  end if;
  if i.status not in ('initiated', 'awaiting_employee', 'under_review', 'changes_required', 'blocked', 'ready_for_activation') then
    raise exception 'Pay after activation is changed in Payroll' using errcode = '22023';
  end if;
  if p_pay_type not in ('monthly', 'hourly') then raise exception 'Pay type must be monthly or hourly' using errcode = '22023'; end if;
  if coalesce(v_amount, 0) <= 0 or round(v_amount, 2) <> v_amount then raise exception 'Enter an amount above zero' using errcode = '22023'; end if;
  if i.offer_id is not null then select proposed_salary_amount into v_offer from public.offers where id = i.offer_id; end if;
  if v_offer is not null and p_pay_type = 'monthly' and v_offer <> p_basic_monthly
     and nullif(btrim(coalesce(p_variance_reason, '')), '') is null then
    raise exception 'The pay differs from the accepted offer (%). Give a reason for the difference.', v_offer using errcode = '22023';
  end if;
  select * into v_old from public.onboarding_pending_compensation where instance_id = i.id;
  insert into public.onboarding_pending_compensation (instance_id, pay_type, basic_monthly, hourly_rate, overtime_eligible, effective_from,
    reason, offer_amount, variance_reason, status, set_by, set_at)
  values (i.id, p_pay_type, case when p_pay_type = 'monthly' then p_basic_monthly end, case when p_pay_type = 'hourly' then p_hourly_rate end,
    coalesce(p_overtime_eligible, true), coalesce(p_effective_from, i.proposed_start_date), nullif(btrim(coalesce(p_reason, '')), ''),
    v_offer, nullif(btrim(coalesce(p_variance_reason, '')), ''), 'pending_review', auth.uid(), now())
  on conflict (instance_id) do update set pay_type = excluded.pay_type, basic_monthly = excluded.basic_monthly,
    hourly_rate = excluded.hourly_rate, overtime_eligible = excluded.overtime_eligible, effective_from = excluded.effective_from,
    reason = excluded.reason, offer_amount = excluded.offer_amount, variance_reason = excluded.variance_reason,
    status = 'pending_review', set_by = excluded.set_by, set_at = now(), reviewed_by = null, reviewed_at = null, review_reason = null;
  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, employee_id)
  values ('onboarding_pending_compensation', i.id, auth.uid(), 'onboarding_pay_set',
    case when v_old.instance_id is not null then jsonb_build_object('pay_type', v_old.pay_type, 'basic_monthly', v_old.basic_monthly,
      'hourly_rate', v_old.hourly_rate, 'status', v_old.status) end,
    jsonb_build_object('pay_type', p_pay_type, 'basic_monthly', p_basic_monthly, 'hourly_rate', p_hourly_rate,
      'offer_amount', v_offer, 'variance_reason', p_variance_reason, 'operation_id', public._onb_op(), 'onboarding_instance_id', i.id),
    i.entity_id, i.employee_id);
  perform public._onb_touch(i.id);
  perform public._onb_recompute(i.id);
  return jsonb_build_object('ok', true, 'status', 'pending_review', 'differs_from_offer', v_offer is not null and v_offer <> v_amount);
end;
$$;

create or replace function public.review_onboarding_compensation(p_instance_id uuid, p_decision text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare c public.onboarding_pending_compensation; i public.onboarding_instances;
begin
  select * into i from public.onboarding_instances where id = p_instance_id;
  if i.id is null then raise exception 'Onboarding not found' using errcode = 'P0002'; end if;
  perform public._onb_require(i.id, 'payroll');
  select * into c from public.onboarding_pending_compensation where instance_id = i.id for update;
  if c.instance_id is null or c.status <> 'pending_review' then raise exception 'No pay is waiting for review' using errcode = '22023'; end if;
  if p_decision not in ('approved', 'changes_required') then raise exception 'Decision must be approved or changes_required' using errcode = '22023'; end if;
  if p_decision = 'changes_required' and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required' using errcode = '22023';
  end if;
  if c.set_by = auth.uid() and public.my_role() <> 'owner' then
    raise exception 'You entered this pay; another payroll approver must review it' using errcode = '42501';
  end if;
  if i.employee_id = public.my_employee_id() then raise exception 'You cannot review your own pay' using errcode = '42501'; end if;
  update public.onboarding_pending_compensation set status = p_decision, reviewed_by = auth.uid(), reviewed_at = now(),
         review_reason = nullif(btrim(coalesce(p_reason, '')), '') where instance_id = i.id;
  insert into public.onboarding_reviews (instance_id, section, reviewer_id, reviewer_role, decision, reason)
  values (i.id, 'payroll', auth.uid(), 'payroll', p_decision, nullif(btrim(coalesce(p_reason, '')), ''));
  perform public._onb_audit(i.id, 'onboarding_pending_compensation', i.id, 'onboarding_pay_reviewed', null,
    jsonb_build_object('decision', p_decision, 'reason', p_reason));
  perform public._onb_touch(i.id);
  perform public._onb_recompute(i.id);
  return jsonb_build_object('ok', true, 'status', p_decision);
end;
$$;

create or replace function public.verify_payment_details(p_payment_details_id uuid, p_decision text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare pd public.employee_payment_details; v_inst uuid; v_entity uuid;
begin
  select * into pd from public.employee_payment_details where id = p_payment_details_id for update;
  if pd.id is null then raise exception 'Payment details not found' using errcode = 'P0002'; end if;
  v_entity := public.payroll_employee_entity(pd.employee_id);
  if not public.payroll_can(v_entity, 'approve') then raise exception 'Only payroll approvers can verify bank details' using errcode = '42501'; end if;
  if pd.status <> 'submitted' then raise exception 'These details are not waiting for verification' using errcode = '22023'; end if;
  if pd.submitted_by = auth.uid() and public.my_role() <> 'owner' then
    raise exception 'You entered these details; someone else must verify them' using errcode = '42501';
  end if;
  if pd.employee_id = public.my_employee_id() then raise exception 'You cannot verify your own bank details' using errcode = '42501'; end if;
  if p_decision not in ('verified', 'rejected') then raise exception 'Decision must be verified or rejected' using errcode = '22023'; end if;
  if p_decision = 'rejected' and nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  update public.employee_payment_details set status = p_decision, verified_by = auth.uid(), verified_at = now(),
         rejection_reason = case when p_decision = 'rejected' then btrim(p_reason) end where id = pd.id;
  select id into v_inst from public.onboarding_instances where employee_id = pd.employee_id
     and status not in ('completed', 'cancelled', 'withdrawn') order by created_at desc limit 1;
  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, employee_id)
  values ('employee_payment_details', pd.id, auth.uid(), 'payment_details_' || p_decision,
    jsonb_build_object('reason', p_reason, 'iban_last4', right(pd.iban, 4), 'operation_id', public._onb_op(), 'onboarding_instance_id', v_inst),
    v_entity, pd.employee_id);
  if v_inst is not null then
    if p_decision = 'rejected' then
      perform public.create_notification(v_entity, null, pd.employee_id, 'onboarding_changes_required', 'Check your bank details',
        btrim(p_reason), 'onboarding_instance', v_inst, 'high', format('onb:%s:bank:%s', v_inst, pd.id));
    end if;
    perform public._onb_touch(v_inst);
    perform public._onb_recompute(v_inst);
  end if;
  return jsonb_build_object('ok', true, 'status', p_decision);
end;
$$;

create or replace function public.raise_onboarding_exception(p_instance_id uuid, p_type text, p_description text,
  p_owner_role text default 'hr', p_is_blocking boolean default true, p_due_date date default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_id uuid; i public.onboarding_instances;
begin
  perform public._onb_require(p_instance_id, 'operate');
  select * into i from public.onboarding_instances where id = p_instance_id;
  if i.status in ('completed', 'cancelled', 'withdrawn') then raise exception 'This onboarding is closed' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p_description, '')), '') is null then raise exception 'Describe the problem' using errcode = '22023'; end if;
  insert into public.onboarding_exceptions (instance_id, exception_type, is_blocking, description, owner_role, due_date, raised_by)
  values (i.id, p_type, coalesce(p_is_blocking, true), btrim(p_description), coalesce(p_owner_role, 'hr'), p_due_date, auth.uid())
  returning id into v_id;
  perform public._onb_audit(i.id, 'onboarding_exceptions', v_id, 'onboarding_exception_raised', null,
    jsonb_build_object('type', p_type, 'blocking', p_is_blocking, 'owner_role', p_owner_role));
  perform public._onb_touch(i.id);
  perform public._onb_recompute(i.id);
  return jsonb_build_object('ok', true, 'exception_id', v_id);
end;
$$;

create or replace function public.resolve_onboarding_exception(p_exception_id uuid, p_resolution text, p_cancel boolean default false)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare x public.onboarding_exceptions;
begin
  select * into x from public.onboarding_exceptions where id = p_exception_id for update;
  if x.id is null then raise exception 'Exception not found' using errcode = 'P0002'; end if;
  if not public._onb_can_own(x.instance_id, x.owner_role) and not public._onb_can(x.instance_id, 'manage') then
    raise exception 'This item belongs to the % role', x.owner_role using errcode = '42501';
  end if;
  if x.status <> 'open' then return jsonb_build_object('ok', true, 'already', true); end if;
  if nullif(btrim(coalesce(p_resolution, '')), '') is null then raise exception 'Say how it was resolved' using errcode = '22023'; end if;
  update public.onboarding_exceptions set status = case when p_cancel then 'cancelled' else 'resolved' end,
         resolution = btrim(p_resolution), resolved_by = auth.uid(), resolved_at = now() where id = x.id;
  perform public._onb_audit(x.instance_id, 'onboarding_exceptions', x.id, 'onboarding_exception_resolved', null,
    jsonb_build_object('resolution', p_resolution, 'cancelled', p_cancel));
  perform public._onb_touch(x.instance_id);
  perform public._onb_recompute(x.instance_id);
  return jsonb_build_object('ok', true, 'already', false);
end;
$$;

create or replace function public.onboarding_dashboard_summary(p_entity_id uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare
  v_role public.user_role := public.my_role();
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  r jsonb;
begin
  if not public.is_active_user() or not (v_role = 'owner' or (v_role in ('entity_admin', 'location_manager') and p_entity_id = public.my_entity())
          or public.payroll_can(p_entity_id, 'approve')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  with scope as (
    select i.* from public.onboarding_instances i
     where i.entity_id = p_entity_id
       and (v_role in ('owner', 'entity_admin') or public.payroll_can(p_entity_id, 'approve')
            or (v_role = 'location_manager' and i.home_location_id = public.my_location())))
  select jsonb_build_object(
    'open', count(*) filter (where status not in ('completed', 'cancelled', 'withdrawn')),
    'by_status', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from scope group by status) s), '{}'::jsonb),
    'starting_7_days', count(*) filter (where status not in ('completed', 'cancelled', 'withdrawn', 'activated', 'day_one', 'in_progress')
                                         and proposed_start_date between v_today and v_today + 7),
    'start_at_risk', count(*) filter (where status not in ('ready_for_activation', 'completed', 'cancelled', 'withdrawn', 'activated', 'day_one', 'in_progress')
                                       and proposed_start_date <= v_today + 3),
    'ready_for_activation', count(*) filter (where status = 'ready_for_activation'),
    'awaiting_review', (select count(*) from public.onboarding_tasks t join scope s on s.id = t.instance_id where t.status = 'submitted'),
    'overdue_tasks', (select count(*) from public.onboarding_tasks t join scope s on s.id = t.instance_id
                       where t.status not in ('approved', 'waived', 'cancelled') and t.due_date < v_today
                         and s.status not in ('completed', 'cancelled', 'withdrawn')),
    'open_exceptions', (select count(*) from public.onboarding_exceptions x join scope s on s.id = x.instance_id where x.status = 'open'),
    'pay_awaiting_review', case when public.payroll_can(p_entity_id, 'approve')
      then (select count(*) from public.onboarding_pending_compensation c join scope s on s.id = c.instance_id where c.status = 'pending_review') end,
    'bank_awaiting_verification', case when public.payroll_can(p_entity_id, 'approve')
      then (select count(*) from public.employee_payment_details pd join scope s on s.employee_id = pd.employee_id where pd.status = 'submitted') end,
    'probation_reviews_due', (select count(*) from public.employee_probation_periods pp join public.employees e on e.id = pp.employee_id
                               where e.entity_id = p_entity_id and pp.status = 'active' and pp.review_due_date <= v_today
                                 and (v_role <> 'location_manager' or e.home_location_id = public.my_location())))
    into r from scope;
  return r;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['review_onboarding_section(uuid, text, text, text)', 'review_onboarding_task(uuid, text, text)',
    'waive_onboarding_task(uuid, text)',
    'set_onboarding_pending_compensation(uuid, date, text, numeric, numeric, boolean, text, text)',
    'review_onboarding_compensation(uuid, text, text)', 'verify_payment_details(uuid, text, text)',
    'raise_onboarding_exception(uuid, text, text, text, boolean, date)', 'resolve_onboarding_exception(uuid, text, boolean)',
    'onboarding_dashboard_summary(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;;
