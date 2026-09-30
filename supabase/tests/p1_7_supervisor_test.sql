-- P1-7 shift supervisor access test. Self-contained: builds throwaway data, runs every check as the
-- supervisor and ends with RAISE, so nothing is kept. Expected output (one line):
--   profile=shift_supervisor grant-no-branch:refused grant-wrong-branch:refused today-A:ok swaps=2 leave=0
--   today-B:refused exc-A:4 exc-B:refused fix-col:ok fix-own:refused fix-B:refused swap-own:refused cover:ok
--   change-time:refused assign-self:refused swap:ok reassign:ok edit-emp:refused leave:refused pay:refused
--   transfer:refused payable-overview:refused payroll_can=false self-absence:ok | rls employees-visible=1 shifts-visible=1
-- Needs an active owner profile; set v_owner below.
do $$
declare v_owner uuid := '045a3ad2-0cbe-4c5e-85bf-df27dd29e14f';
  v_ent uuid; a uuid; b uuid; e_sup uuid; e_col uuid; e_col2 uuid; e_b uuid; sh uuid; sh_own uuid; sw uuid; sw_own uuid; ar_col uuid; ar_own uuid; ar_b uuid; lt uuid;
  u_sup uuid := gen_random_uuid(); u_col uuid := gen_random_uuid();
  t date := (now() at time zone 'Asia/Dubai')::date; r jsonb; out text := ''; ok text;
  n_emp int; n_sh int; v_prole text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.entities(name) values ('ZZ P17') returning id into v_ent;
  insert into public.locations(entity_id,name) values (v_ent,'A') returning id into a;
  insert into public.locations(entity_id,name) values (v_ent,'B') returning id into b;
  insert into public.leave_types(entity_id,name,accrual_days_per_year,requires_approval) values (v_ent,'Sick Leave',0,true) returning id into lt;
  insert into auth.users(id,email,aud,role) values (u_sup,'zz-p17-sup@example.invalid','authenticated','authenticated'),(u_col,'zz-p17-col@example.invalid','authenticated','authenticated');
  insert into public.employees(entity_id,home_location_id,full_name,employment_status,auth_user_id) values (v_ent,a,'ZZ Sup','active',u_sup) returning id into e_sup;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status,auth_user_id) values (v_ent,a,'ZZ Col','active',u_col) returning id into e_col;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (v_ent,a,'ZZ Col2','active') returning id into e_col2;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (v_ent,b,'ZZ AtB','active') returning id into e_b;
  perform public.admin_grant_access('zz-p17-sup@example.invalid', 'shift_supervisor', v_ent, a, e_sup);
  perform public.admin_grant_access('zz-p17-col@example.invalid', 'staff', v_ent, a, e_col);
  select role::text into v_prole from public.profiles where id = u_sup; out := out || 'profile=' || coalesce(v_prole,'none') || ' ';
  begin perform public.admin_grant_access('zz-p17-x@example.invalid', 'shift_supervisor', v_ent, null, e_col2); out := out || 'grant-no-branch:ALLOWED '; exception when others then out := out || 'grant-no-branch:refused '; end;
  begin perform public.admin_grant_access('zz-p17-y@example.invalid', 'shift_supervisor', v_ent, b, e_col2); out := out || 'grant-wrong-branch:ALLOWED '; exception when others then out := out || 'grant-wrong-branch:refused '; end;
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (v_ent,a,e_col,t+1,'09:00','17:00',true) returning id into sh;
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (v_ent,a,e_sup,t+2,'09:00','17:00',true) returning id into sh_own;
  insert into public.shift_swap_requests(shift_id,requested_by,claimed_by,status) values (sh,e_col,e_col2,'claimed') returning id into sw;
  insert into public.shift_swap_requests(shift_id,requested_by,claimed_by,status) values (sh_own,e_sup,e_col,'claimed') returning id into sw_own;
  insert into public.attendance_records(entity_id,location_id,employee_id,clock_in_at) values (v_ent,a,e_col,now()-interval '26 hours') returning id into ar_col;
  insert into public.attendance_records(entity_id,location_id,employee_id,clock_in_at) values (v_ent,a,e_sup,now()-interval '26 hours') returning id into ar_own;
  insert into public.attendance_records(entity_id,location_id,employee_id,clock_in_at) values (v_ent,b,e_b,now()-interval '26 hours') returning id into ar_b;
  insert into public.leave_requests(employee_id,leave_type_id,start_date,end_date,days_requested,status) values (e_col,lt,t+5,t+5,1,'pending');

  perform set_config('request.jwt.claims', json_build_object('sub',u_sup,'role','authenticated')::text, true);
  r := public.get_branch_today(a);
  out := out || format('today-A:ok swaps=%s leave=%s ', jsonb_array_length(r->'pending_swaps'), r->'approvals'->>'leave');
  begin perform public.get_branch_today(b); out := out || 'today-B:ALLOWED '; exception when others then out := out || 'today-B:refused '; end;
  select count(*)::text into ok from public.get_attendance_exceptions(a, t-7, t); out := out || 'exc-A:' || ok || ' ';
  begin perform public.get_attendance_exceptions(b, t-7, t); out := out || 'exc-B:ALLOWED '; exception when others then out := out || 'exc-B:refused '; end;
  begin perform public.correct_attendance_record(ar_col, null, now()-interval '18 hours', 'forgot'); out := out || 'fix-col:ok '; exception when others then out := out || 'fix-col:FAIL(' || sqlerrm || ') '; end;
  begin perform public.correct_attendance_record(ar_own, null, now()-interval '18 hours', 'me'); out := out || 'fix-own:ALLOWED '; exception when others then out := out || 'fix-own:refused '; end;
  begin perform public.correct_attendance_record(ar_b, null, now()-interval '18 hours', 'x'); out := out || 'fix-B:ALLOWED '; exception when others then out := out || 'fix-B:refused '; end;
  begin perform public.approve_shift_swap(sw_own, 'approve'); out := out || 'swap-own:ALLOWED '; exception when others then out := out || 'swap-own:refused '; end;
  begin perform public.suggest_shift_cover(sh); out := out || 'cover:ok '; exception when others then out := out || 'cover:FAIL(' || sqlerrm || ') '; end;
  begin perform public.adjust_published_shift(sh, 'longer', t+1, '09:00', '18:00', null, e_col2, a); out := out || 'change-time:ALLOWED '; exception when others then out := out || 'change-time:refused '; end;
  begin perform public.adjust_published_shift(sh, 'me', t+1, '09:00', '17:00', null, e_sup, a); out := out || 'assign-self:ALLOWED '; exception when others then out := out || 'assign-self:refused '; end;
  begin perform public.approve_shift_swap(sw, 'reject'); out := out || 'swap:ok '; exception when others then out := out || 'swap:FAIL(' || sqlerrm || ') '; end;
  begin perform public.adjust_published_shift(sh, 'cover', t+1, '09:00', '17:00', null, e_col2, a); out := out || 'reassign:ok '; exception when others then out := out || 'reassign:FAIL(' || sqlerrm || ') '; end;
  begin perform public.update_employee_details(e_col, '{"phone":"+971500000009"}'); out := out || 'edit-emp:ALLOWED '; exception when others then out := out || 'edit-emp:refused '; end;
  begin perform public.approve_leave_request((select id from public.leave_requests where employee_id=e_col limit 1), 'approve'); out := out || 'leave:ALLOWED '; exception when others then out := out || 'leave:refused '; end;
  begin perform public.get_employee_compensation(e_col); out := out || 'pay:ALLOWED '; exception when others then out := out || 'pay:refused '; end;
  begin perform public.transfer_employee(e_col, b, t, 'x'); out := out || 'transfer:ALLOWED '; exception when others then out := out || 'transfer:refused '; end;
  begin perform public.get_location_attendance_overview(a, t-7, t); out := out || 'payable-overview:ALLOWED '; exception when others then out := out || 'payable-overview:refused '; end;
  out := out || 'payroll_can=' || public.payroll_can(v_ent, 'view_pay')::text || ' ';
  begin perform public.report_absence(sh_own, lt, 'sick'); out := out || 'self-absence:ok '; exception when others then out := out || 'self-absence:FAIL(' || sqlerrm || ') '; end;
  perform set_config('role', 'authenticated', true);
  select count(*) into n_emp from public.employees where entity_id = v_ent;
  select count(*) into n_sh from public.shifts where entity_id = v_ent;
  raise exception 'RESULT % | rls employees-visible=% shifts-visible=%', out, n_emp, n_sh;
end $$;
