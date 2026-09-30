-- Suite 06: transfer_employee (who may transfer, validation, immediate vs scheduled, scope follows the move).
-- Self-contained; the final RAISE 'RESULT ...' rolls back everything.
do $$
declare
  v_owner uuid := '045a3ad2-0cbe-4c5e-85bf-df27dd29e14f';
  e1 uuid; e2 uuid; la uuid; lb uuid; lc uuid;
  u_adm uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_mgrb uuid := gen_random_uuid();
  u_st uuid := gen_random_uuid(); u_st2 uuid := gen_random_uuid(); u_none uuid := gen_random_uuid();
  e_mgr uuid; e_mgrb uuid; e_st uuid; e_st2 uuid; e_inact uuid; e_c uuid;
  t date := (now() at time zone 'Asia/Dubai')::date;
  r text[] := '{}'; n int; res jsonb; v_loc uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.entities(name) values ('ZZ S06 E1') returning id into e1;
  insert into public.entities(name) values ('ZZ S06 E2') returning id into e2;
  insert into public.locations(entity_id,name) values (e1,'ZZ A') returning id into la;
  insert into public.locations(entity_id,name) values (e1,'ZZ B') returning id into lb;
  insert into public.locations(entity_id,name) values (e2,'ZZ C') returning id into lc;
  insert into auth.users(id,email,aud,role) values
    (u_adm,'zz-s06-adm@example.invalid','authenticated','authenticated'),(u_mgr,'zz-s06-mgr@example.invalid','authenticated','authenticated'),
    (u_mgrb,'zz-s06-mgrb@example.invalid','authenticated','authenticated'),(u_st,'zz-s06-st@example.invalid','authenticated','authenticated'),
    (u_st2,'zz-s06-st2@example.invalid','authenticated','authenticated'),(u_none,'zz-s06-none@example.invalid','authenticated','authenticated');
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Mgr','active') returning id into e_mgr;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,lb,'ZZ MgrB','active') returning id into e_mgrb;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ St','active') returning id into e_st;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ St2','active') returning id into e_st2;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Gone','inactive') returning id into e_inact;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e2,lc,'ZZ AtC','active') returning id into e_c;
  perform public.admin_grant_access('zz-s06-adm@example.invalid','entity_admin',e1,null,null);
  perform public.admin_grant_access('zz-s06-mgr@example.invalid','location_manager',e1,la,e_mgr);
  perform public.admin_grant_access('zz-s06-mgrb@example.invalid','location_manager',e1,lb,e_mgrb);
  perform public.admin_grant_access('zz-s06-st@example.invalid','staff',e1,la,e_st);
  perform public.admin_grant_access('zz-s06-st2@example.invalid','staff',e1,la,e_st2);

  perform set_config('role','authenticated',true);
  -- ===== who may not transfer =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  begin perform public.transfer_employee(e_st, lb, t, 'me'); r := r || 'FAIL transfer: staff refused (allowed)'::text;
  exception when others then r := r || 'PASS transfer: staff refused'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin perform public.transfer_employee(e_st, lb, t, 'mgr'); r := r || 'FAIL transfer: location manager refused (allowed)'::text;
  exception when others then r := r || 'PASS transfer: location manager refused'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_none, 'role', 'authenticated')::text, true);
  begin perform public.transfer_employee(e_st, lb, t, 'nobody'); r := r || 'FAIL transfer: login without profile refused (allowed)'::text;
  exception when others then r := r || 'PASS transfer: login without profile refused'::text; end;

  -- ===== validation (entity admin of E1) =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  begin perform public.transfer_employee(e_c, lc, t, 'other co'); r := r || 'FAIL transfer: entity admin cannot transfer another company''s employee (allowed)'::text;
  exception when others then r := r || 'PASS transfer: entity admin cannot transfer another company''s employee'::text; end;
  begin perform public.transfer_employee(e_st, lc, t, 'cross'); r := r || 'FAIL transfer: cross-company branch refused (allowed)'::text;
  exception when others then r := r || 'PASS transfer: cross-company branch refused'::text; end;
  begin perform public.transfer_employee(e_st, la, t, 'same'); r := r || 'FAIL transfer: same branch refused (allowed)'::text;
  exception when others then r := r || 'PASS transfer: same branch refused'::text; end;
  begin perform public.transfer_employee(e_st, lb, t, '   '); r := r || 'FAIL transfer: reason required (allowed)'::text;
  exception when others then r := r || 'PASS transfer: reason required'::text; end;
  begin perform public.transfer_employee(e_st, lb, t - 1, 'late'); r := r || 'FAIL transfer: past date refused (allowed)'::text;
  exception when others then r := r || 'PASS transfer: past date refused'::text; end;
  begin perform public.transfer_employee(e_inact, lb, t, 'gone'); r := r || 'FAIL transfer: inactive employee refused (allowed)'::text;
  exception when others then r := r || 'PASS transfer: inactive employee refused'::text; end;

  -- ===== immediate transfer (today) =====
  begin
    res := public.transfer_employee(e_st, lb, t, 'ZZ needed at B');
    r := r || (case when res->>'status' = 'completed' then 'PASS ' else 'FAIL ' end || format('transfer: effective today completes immediately (%s)', res->>'status'));
  exception when others then r := r || ('FAIL transfer: entity admin transfers today (' || sqlerrm || ')'); end;
  perform set_config('role','postgres',true);
  r := r || (case when (select home_location_id from public.employees where id = e_st) = lb then 'PASS ' else 'FAIL ' end || 'transfer: employee home branch moved');
  select location_id into v_loc from public.profiles where id = u_st;
  r := r || (case when v_loc = lb then 'PASS ' else 'FAIL ' end || 'transfer: staff login scope follows to new branch');
  select count(*) into n from public.notifications where employee_id = e_st and notification_type = 'employee_transferred';
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'transfer: employee notified');
  select count(*) into n from public.notifications where recipient_user_id = u_mgrb and notification_type = 'employee_transferred';
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'transfer: receiving manager notified');
  select count(*) into n from public.notifications where recipient_user_id = u_mgr and notification_type = 'employee_transfer_scheduled';
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'transfer: losing manager notified');
  select count(*) into n from public.audit_log where employee_id = e_st and action in ('employee_transfer_scheduled','employee_transferred');
  r := r || (case when n = 2 then 'PASS ' else 'FAIL ' end || 'transfer: scheduled + completed audited');
  -- RLS scope after the move
  perform set_config('role','authenticated',true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  select count(*) into n from public.employees where id = e_st;
  r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'transfer: old branch manager no longer sees employee');
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgrb, 'role', 'authenticated')::text, true);
  select count(*) into n from public.employees where id = e_st;
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'transfer: new branch manager sees employee');

  -- ===== scheduled transfer (future) by owner =====
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    res := public.transfer_employee(e_st2, lb, t + 7, 'ZZ next week');
    r := r || (case when res->>'status' = 'scheduled' then 'PASS ' else 'FAIL ' end || format('transfer: future date is scheduled (%s)', res->>'status'));
  exception when others then r := r || ('FAIL transfer: owner schedules future transfer (' || sqlerrm || ')'); end;
  begin perform public.transfer_employee(e_st2, lb, t + 8, 'again'); r := r || 'FAIL transfer: second scheduled transfer refused (allowed)'::text;
  exception when others then r := r || 'PASS transfer: second scheduled transfer refused'::text; end;
  perform set_config('role','postgres',true);
  r := r || (case when (select home_location_id from public.employees where id = e_st2) = la then 'PASS ' else 'FAIL ' end || 'transfer: scheduled transfer leaves home branch unchanged until the date');

  raise exception 'RESULT suite06 pass=% fail=% :: %',
    (select count(*) from unnest(r) x where x like 'PASS%'), (select count(*) from unnest(r) x where x like 'FAIL%'),
    array_to_string(r, '; ');
end $$;
