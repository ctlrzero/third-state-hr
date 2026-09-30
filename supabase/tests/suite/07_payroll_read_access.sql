-- Suite 07: payroll READ access - permission checks only for get_payroll_readiness / get_payroll_changes
-- and payroll_can(). Read-only against payroll data: it creates two EMPTY throwaway payroll periods and
-- payroll_permissions presets for throwaway users; it never creates or changes payroll_records or money.
-- The final RAISE 'RESULT ...' rolls back everything.
do $$
declare
  v_owner uuid := '045a3ad2-0cbe-4c5e-85bf-df27dd29e14f';
  e1 uuid; e2 uuid; la uuid; p1 uuid; p2 uuid;
  u_adm uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_st uuid := gen_random_uuid();
  u_acc uuid := gen_random_uuid(); u_pa uuid := gen_random_uuid(); u_rev uuid := gen_random_uuid(); u_none uuid := gen_random_uuid();
  e_mgr uuid; e_st uuid; e_acc uuid; e_pa uuid; e_rev uuid;
  r text[] := '{}'; c record; ok boolean; err text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.entities(name) values ('ZZ S07 E1') returning id into e1;
  insert into public.entities(name) values ('ZZ S07 E2') returning id into e2;
  insert into public.locations(entity_id,name) values (e1,'ZZ A') returning id into la;
  insert into auth.users(id,email,aud,role) values
    (u_adm,'zz-s07-adm@example.invalid','authenticated','authenticated'),(u_mgr,'zz-s07-mgr@example.invalid','authenticated','authenticated'),
    (u_st,'zz-s07-st@example.invalid','authenticated','authenticated'),(u_acc,'zz-s07-acc@example.invalid','authenticated','authenticated'),
    (u_pa,'zz-s07-pa@example.invalid','authenticated','authenticated'),(u_rev,'zz-s07-rev@example.invalid','authenticated','authenticated'),
    (u_none,'zz-s07-none@example.invalid','authenticated','authenticated');
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Mgr','active') returning id into e_mgr;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ St','active') returning id into e_st;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Accountant','active') returning id into e_acc;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ PayrollAdmin','active') returning id into e_pa;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ RevokedPA','active') returning id into e_rev;
  perform public.admin_grant_access('zz-s07-adm@example.invalid','entity_admin',e1,null,null);
  perform public.admin_grant_access('zz-s07-mgr@example.invalid','location_manager',e1,la,e_mgr);
  perform public.admin_grant_access('zz-s07-st@example.invalid','staff',e1,la,e_st);
  perform public.admin_grant_access('zz-s07-acc@example.invalid','staff',e1,la,e_acc);
  perform public.admin_grant_access('zz-s07-pa@example.invalid','staff',e1,la,e_pa);
  perform public.admin_grant_access('zz-s07-rev@example.invalid','staff',e1,la,e_rev);
  insert into public.payroll_permissions(user_id,entity_id,preset,granted_by) values
    (u_acc,e1,'accountant',v_owner),(u_pa,e1,'payroll_admin',v_owner),(u_rev,e1,'payroll_admin',v_owner);
  perform public.admin_revoke_access(u_rev, null, 'ZZ suite: revoked payroll admin');
  insert into public.payroll_periods(entity_id,period_start,period_end,label,created_by) values (e1,'2099-01-01','2099-01-31','ZZ S07 P1',v_owner) returning id into p1;
  insert into public.payroll_periods(entity_id,period_start,period_end,label,created_by) values (e2,'2099-01-01','2099-01-31','ZZ S07 P2',v_owner) returning id into p2;

  perform set_config('role','authenticated',true);
  for c in
    select * from (values
      ('owner',            v_owner, 'P1', true,  true,  true),
      ('owner',            v_owner, 'P2', true,  true,  true),
      ('entity_admin',     u_adm,   'P1', true,  true,  true),
      ('entity_admin',     u_adm,   'P2', false, false, false),
      ('location_manager', u_mgr,   'P1', false, false, false),
      ('staff',            u_st,    'P1', false, false, false),
      ('accountant',       u_acc,   'P1', false, true,  true),
      ('payroll_admin',    u_pa,    'P1', true,  true,  true),
      ('payroll_admin',    u_pa,    'P2', false, false, false),
      ('revoked payroll_admin', u_rev, 'P1', false, false, false),
      ('no-profile login', u_none,  'P1', false, false, false)
    ) v(who, uid, per, exp_ready, exp_changes, exp_view)
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', c.uid, 'role', 'authenticated')::text, true);
    begin perform public.get_payroll_readiness(case c.per when 'P1' then p1 else p2 end); ok := true; err := null;
    exception when others then ok := false; err := sqlerrm; end;
    r := r || (case when ok = c.exp_ready then 'PASS ' else 'FAIL ' end
               || format('payroll: %s get_payroll_readiness(%s) %s', c.who, c.per, case when ok then 'allowed' else 'refused' end)
               || case when ok <> c.exp_ready and err is not null then ' (' || err || ')' else '' end);
    begin perform public.get_payroll_changes(case c.per when 'P1' then p1 else p2 end); ok := true; err := null;
    exception when others then ok := false; err := sqlerrm; end;
    r := r || (case when ok = c.exp_changes then 'PASS ' else 'FAIL ' end
               || format('payroll: %s get_payroll_changes(%s) %s', c.who, c.per, case when ok then 'allowed' else 'refused' end)
               || case when ok <> c.exp_changes and err is not null then ' (' || err || ')' else '' end);
    ok := public.payroll_can(case c.per when 'P1' then e1 else e2 end, 'view_pay');
    r := r || (case when ok = c.exp_view then 'PASS ' else 'FAIL ' end || format('payroll: %s payroll_can(view_pay,%s)=%s', c.who, c.per, ok));
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin perform public.get_payroll_readiness(gen_random_uuid()); r := r || 'FAIL payroll: unknown period refused (allowed)'::text;
  exception when others then r := r || 'PASS payroll: unknown period refused'::text; end;
  r := r || (case when public.payroll_can(e1, 'inputs') then 'PASS ' else 'FAIL ' end || 'payroll: owner payroll_can(inputs)');
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  r := r || (case when public.payroll_can(e1, 'inputs') and not public.payroll_can(e1, 'approve') then 'PASS ' else 'FAIL ' end || 'payroll: manager may give inputs only');
  perform set_config('request.jwt.claims', json_build_object('sub', u_acc, 'role', 'authenticated')::text, true);
  r := r || (case when public.payroll_can(e1, 'report') and not public.payroll_can(e1, 'prepare') and not public.payroll_can(e1, 'approve') then 'PASS ' else 'FAIL ' end || 'payroll: accountant may view/report but not prepare/approve');
  perform set_config('role','postgres',true);

  raise exception 'RESULT suite07 pass=% fail=% :: %',
    (select count(*) from unnest(r) x where x like 'PASS%'), (select count(*) from unnest(r) x where x like 'FAIL%'),
    array_to_string(r, '; ');
end $$;
