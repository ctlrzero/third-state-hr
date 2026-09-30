-- Suite 02: leave request -> approve/reject -> shifts on leave flagged.
-- Self-contained, rolled back by the final RAISE 'RESULT ...'. Actions run as the API role
-- (role=authenticated + request.jwt.claims); verification reads switch back to postgres.
do $$
declare
  v_owner uuid := '045a3ad2-0cbe-4c5e-85bf-df27dd29e14f';
  e1 uuid; la uuid; lb uuid; lt uuid;
  u_adm uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_mgrx uuid := gen_random_uuid(); u_mgrb uuid := gen_random_uuid();
  u_sup uuid := gen_random_uuid(); u_st uuid := gen_random_uuid(); u_st2 uuid := gen_random_uuid();
  e_mgr uuid; e_mgrx uuid; e_mgrb uuid; e_sup uuid; e_st uuid; e_st2 uuid;
  lr uuid; lr_big uuid; lr_rej uuid; lr_mgr uuid;
  t date := (now() at time zone 'Asia/Dubai')::date;
  r text[] := '{}'; n int; bal numeric; res jsonb; ok boolean; st text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.entities(name) values ('ZZ S02') returning id into e1;
  insert into public.locations(entity_id,name) values (e1,'ZZ A') returning id into la;
  insert into public.locations(entity_id,name) values (e1,'ZZ B') returning id into lb;
  insert into public.leave_types(entity_id,name,accrual_days_per_year,requires_approval) values (e1,'ZZ Annual',10,true) returning id into lt;
  insert into auth.users(id,email,aud,role) values
    (u_adm,'zz-s02-adm@example.invalid','authenticated','authenticated'),(u_mgr,'zz-s02-mgr@example.invalid','authenticated','authenticated'),
    (u_mgrx,'zz-s02-mgrx@example.invalid','authenticated','authenticated'),(u_mgrb,'zz-s02-mgrb@example.invalid','authenticated','authenticated'),
    (u_sup,'zz-s02-sup@example.invalid','authenticated','authenticated'),(u_st,'zz-s02-st@example.invalid','authenticated','authenticated'),
    (u_st2,'zz-s02-st2@example.invalid','authenticated','authenticated');
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Mgr','active') returning id into e_mgr;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ MgrRevoked','active') returning id into e_mgrx;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,lb,'ZZ MgrB','active') returning id into e_mgrb;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Sup','active') returning id into e_sup;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Staff','active') returning id into e_st;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Staff2','active') returning id into e_st2;
  perform public.admin_grant_access('zz-s02-adm@example.invalid','entity_admin',e1,null,null);
  perform public.admin_grant_access('zz-s02-mgr@example.invalid','location_manager',e1,la,e_mgr);
  perform public.admin_grant_access('zz-s02-mgrx@example.invalid','location_manager',e1,la,e_mgrx);
  perform public.admin_grant_access('zz-s02-mgrb@example.invalid','location_manager',e1,lb,e_mgrb);
  perform public.admin_grant_access('zz-s02-sup@example.invalid','shift_supervisor',e1,la,e_sup);
  perform public.admin_grant_access('zz-s02-st@example.invalid','staff',e1,la,e_st);
  perform public.admin_grant_access('zz-s02-st2@example.invalid','staff',e1,la,e_st2);
  perform public.admin_revoke_access(u_mgrx, null, 'ZZ suite: revoked manager');
  -- shifts for e_st: two inside the leave window (published + draft), one outside, one cancelled inside
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values
    (e1,la,e_st,t+5,'09:00','17:00',true),(e1,la,e_st,t+6,'09:00','17:00',false),(e1,la,e_st,t+9,'09:00','17:00',true);
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published,status) values
    (e1,la,e_st,t+7,'09:00','17:00',true,'cancelled');
  select balance_days into bal from public.leave_balances where employee_id = e_st and leave_type_id = lt;
  r := r || (case when bal = 10 then 'PASS ' else 'FAIL ' end || format('leave: balance seeded from accrual (=%s, expect 10)', bal));

  -- ===== staff submits leave t+5..t+7 (3 days) =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  perform set_config('role','authenticated',true);
  insert into public.leave_requests(employee_id,leave_type_id,start_date,end_date,days_requested,status) values (e_st,lt,t+5,t+7,3,'pending') returning id into lr;
  perform set_config('role','postgres',true);
  select balance_days into bal from public.leave_balances where employee_id = e_st and leave_type_id = lt;
  select balance_reserved into ok from public.leave_requests where id = lr;
  r := r || (case when bal = 7 and ok then 'PASS ' else 'FAIL ' end || format('leave: submit reserves balance (bal=%s reserved=%s)', bal, ok));
  select count(*) into n from public.notifications where recipient_user_id = u_mgr and notification_type = 'leave_request_submitted' and target_id = lr;
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'leave: branch manager notified of new request');
  select count(*) into n from public.notifications where recipient_user_id = u_mgrx and notification_type = 'leave_request_submitted' and target_id = lr;
  r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || format('leave: revoked (inactive) manager not notified of new request (got %s)', n));

  -- ===== who may NOT decide =====
  perform set_config('role','authenticated',true);
  begin perform public.approve_leave_request(lr, 'approve'); r := r || 'FAIL leave: staff cannot approve own leave (allowed)'::text;
  exception when others then r := r || 'PASS leave: staff cannot approve own leave'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  begin perform public.approve_leave_request(lr, 'approve'); r := r || 'FAIL leave: shift supervisor cannot approve leave (allowed)'::text;
  exception when others then r := r || 'PASS leave: shift supervisor cannot approve leave'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgrb, 'role', 'authenticated')::text, true);
  begin perform public.approve_leave_request(lr, 'approve'); r := r || 'FAIL leave: other-branch manager cannot approve (allowed)'::text;
  exception when others then r := r || 'PASS leave: other-branch manager cannot approve'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgrx, 'role', 'authenticated')::text, true);
  begin perform public.approve_leave_request(lr, 'approve'); r := r || 'FAIL leave: revoked manager cannot approve (allowed)'::text;
  exception when others then r := r || 'PASS leave: revoked manager cannot approve'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin perform public.approve_leave_request(lr, 'maybe'); r := r || 'FAIL leave: invalid action refused (allowed)'::text;
  exception when others then r := r || 'PASS leave: invalid action refused'::text; end;

  -- ===== entity admin approves: shifts on leave are flagged =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  begin
    res := public.approve_leave_request(lr, 'approve');
    r := r || (case when jsonb_array_length(res->'affected_shifts') = 2 then 'PASS ' else 'FAIL ' end
               || format('leave: approval flags the 2 live shifts inside the window (got %s)', jsonb_array_length(res->'affected_shifts')));
    r := r || (case when not exists (select 1 from jsonb_array_elements(res->'affected_shifts') a where (a->>'shift_date')::date not between t+5 and t+7)
               then 'PASS ' else 'FAIL ' end || 'leave: shift outside the window / cancelled shift not flagged');
  exception when others then r := r || ('FAIL leave: entity admin approves (' || sqlerrm || ')'); end;
  perform set_config('role','postgres',true);
  select status into st from public.leave_requests where id = lr;
  select balance_days into bal from public.leave_balances where employee_id = e_st and leave_type_id = lt;
  r := r || (case when st = 'approved' and (select decided_by from public.leave_requests where id = lr) = u_adm then 'PASS ' else 'FAIL ' end || 'leave: status approved and decided_by recorded');
  r := r || (case when bal = 7 then 'PASS ' else 'FAIL ' end || format('leave: reserved balance not deducted twice (bal=%s)', bal));
  select count(*) into n from public.notifications where employee_id = e_st and notification_type = 'leave_approved' and target_id = lr;
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'leave: employee notified of approval');
  select count(*) into n from public.notifications where recipient_user_id = u_mgr and notification_type = 'leave_shift_conflict' and target_id = lr;
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'leave: branch manager gets "shift needs cover" alert');
  select count(*) into n from public.notifications where recipient_user_id = u_mgrx and notification_type = 'leave_shift_conflict' and target_id = lr;
  r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'leave: revoked manager gets no cover alert');
  select jsonb_array_length(new_value->'affected_shift_ids') into n from public.audit_log where record_id = lr and action = 'leave_approved';
  r := r || (case when n = 2 then 'PASS ' else 'FAIL ' end || 'leave: audit_log records affected_shift_ids');

  -- new shift on an approved-leave day is blocked (validate_shift)
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  perform set_config('role','authenticated',true);
  begin
    insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time) values (e1,la,e_st,t+7,'18:00','22:00');
    r := r || 'FAIL leave: cannot schedule someone on approved leave (allowed)'::text;
  exception when others then r := r || (case when sqlerrm ilike '%approved leave%' then 'PASS ' else 'FAIL ' end || 'leave: cannot schedule someone on approved leave (' || sqlerrm || ')'); end;
  begin perform public.approve_leave_request(lr, 'reject'); r := r || 'FAIL leave: already-decided request cannot be decided again (allowed)'::text;
  exception when others then r := r || 'PASS leave: already-decided request cannot be decided again'::text; end;

  -- ===== manager cannot decide own leave =====
  insert into public.leave_requests(employee_id,leave_type_id,start_date,end_date,days_requested,status) values (e_mgr,lt,t+15,t+15,1,'pending') returning id into lr_mgr;
  begin perform public.approve_leave_request(lr_mgr, 'approve'); r := r || 'FAIL leave: manager cannot approve own leave (allowed)'::text;
  exception when others then r := r || 'PASS leave: manager cannot approve own leave'::text; end;

  -- ===== insufficient balance / override rules (e_st2 has 10 days, asks 30) =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_st2, 'role', 'authenticated')::text, true);
  insert into public.leave_requests(employee_id,leave_type_id,start_date,end_date,days_requested,status) values (e_st2,lt,t+30,t+59,30,'pending') returning id into lr_big;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin perform public.approve_leave_request(lr_big, 'approve'); r := r || 'FAIL leave: insufficient balance blocks approval (allowed)'::text;
  exception when others then r := r || (case when sqlerrm ilike 'Insufficient balance%' then 'PASS ' else 'FAIL ' end || 'leave: insufficient balance blocks approval'); end;
  begin perform public.approve_leave_request(lr_big, 'approve', true, 'manager wants it'); r := r || 'FAIL leave: manager cannot override balance (allowed)'::text;
  exception when others then r := r || 'PASS leave: manager cannot override balance'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  begin perform public.approve_leave_request(lr_big, 'approve', true, '  '); r := r || 'FAIL leave: override needs a reason (allowed)'::text;
  exception when others then r := r || 'PASS leave: override needs a reason'::text; end;
  begin perform public.approve_leave_request(lr_big, 'approve', true, 'ZZ approved by admin');
    r := r || 'PASS leave: entity admin override with reason approves'::text;
  exception when others then r := r || ('FAIL leave: entity admin override with reason approves (' || sqlerrm || ')'); end;
  perform set_config('role','postgres',true);
  select balance_days into bal from public.leave_balances where employee_id = e_st2 and leave_type_id = lt;
  r := r || (case when bal = -20 then 'PASS ' else 'FAIL ' end || format('leave: override deducts full days (bal=%s, expect -20)', bal));
  select count(*) into n from public.audit_log where record_id = lr_big and action = 'leave_balance_override_approved';
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'leave: override is audited');

  -- ===== reject releases a reserved balance =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  perform set_config('role','authenticated',true);
  insert into public.leave_requests(employee_id,leave_type_id,start_date,end_date,days_requested,status) values (e_st,lt,t+20,t+21,2,'pending') returning id into lr_rej;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin perform public.approve_leave_request(lr_rej, 'reject'); exception when others then r := r || ('FAIL leave: manager rejects (' || sqlerrm || ')'); end;
  perform set_config('role','postgres',true);
  select balance_days into bal from public.leave_balances where employee_id = e_st and leave_type_id = lt;
  select status into st from public.leave_requests where id = lr_rej;
  r := r || (case when st = 'rejected' and bal = 7 and not (select balance_reserved from public.leave_requests where id = lr_rej) then 'PASS ' else 'FAIL ' end
             || format('leave: reject releases reserved days (status=%s bal=%s)', st, bal));
  select count(*) into n from public.notifications where employee_id = e_st and notification_type = 'leave_rejected' and target_id = lr_rej;
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'leave: employee notified of rejection');

  raise exception 'RESULT suite02 pass=% fail=% :: %',
    (select count(*) from unnest(r) x where x like 'PASS%'), (select count(*) from unnest(r) x where x like 'FAIL%'),
    array_to_string(r, '; ');
end $$;
