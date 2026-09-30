-- P1-5 nightly payable time + clock-out suggestions. Self-contained: builds throwaway data, runs the
-- nightly job as the system (no JWT) and the RPCs as branch managers, then ends with RAISE so nothing
-- is kept. Note: the nightly run also touches the real branches inside this transaction; it is rolled back.
-- Expected output (one line):
--   run1:ok payable=3 sugg=4 no-shift-suggested=null col-suggested=17:00 | run2:ok payable=3 seeded=0 sugg=4
--   | list-A=4 list-B:refused confirm-B:refused confirm-own:refused confirm-noshift:refused confirm:ok
--   out=17:00 orig-in-kept=true corrected=true payable=475 again:refused dismiss-B:refused dismiss:ok
--   | run3:ok sugg=4 dismissed-stays=dismissed list-A=2 system-only:refused
-- Needs an active owner profile; set v_owner below.
do $$
declare v_owner uuid := '045a3ad2-0cbe-4c5e-85bf-df27dd29e14f';
  v_ent uuid; a uuid; b uuid; e_col uuid; e_col2 uuid; e_mgr uuid; e_mgrb uuid; e_nos uuid;
  sh_col uuid; sh_col2 uuid; sh_mgr uuid; ar_col uuid; ar_col2 uuid; ar_mgr uuid; ar_nos uuid;
  s_col uuid; s_col2 uuid; s_mgr uuid; s_nos uuid;
  u_mgr uuid := gen_random_uuid(); u_mgrb uuid := gen_random_uuid();
  t date := (now() at time zone 'Asia/Dubai')::date; y date; r jsonb; out text := ''; n int; v text;
  v_ar public.attendance_records;
begin
  y := t - 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.entities(name) values ('ZZ P15') returning id into v_ent;
  insert into public.locations(entity_id,name,is_active) values (v_ent,'ZZ P15 A',true) returning id into a;
  insert into public.locations(entity_id,name,is_active) values (v_ent,'ZZ P15 B',true) returning id into b;
  insert into auth.users(id,email,aud,role) values
    (u_mgr,'zz-p15-mgr@example.invalid','authenticated','authenticated'),
    (u_mgrb,'zz-p15-mgrb@example.invalid','authenticated','authenticated');
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (v_ent,a,'ZZ Col','active') returning id into e_col;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (v_ent,a,'ZZ Col2','active') returning id into e_col2;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (v_ent,a,'ZZ NoShift','active') returning id into e_nos;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status,auth_user_id) values (v_ent,a,'ZZ Mgr','active',u_mgr) returning id into e_mgr;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status,auth_user_id) values (v_ent,b,'ZZ MgrB','active',u_mgrb) returning id into e_mgrb;
  perform public.admin_grant_access('zz-p15-mgr@example.invalid', 'location_manager', v_ent, a, e_mgr);
  perform public.admin_grant_access('zz-p15-mgrb@example.invalid', 'location_manager', v_ent, b, e_mgrb);

  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published,status) values (v_ent,a,e_col,y,'09:00','17:00',true,'assigned') returning id into sh_col;
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published,status) values (v_ent,a,e_col2,y,'10:00','18:00',true,'assigned') returning id into sh_col2;
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published,status) values (v_ent,a,e_mgr,y,'09:00','17:00',true,'assigned') returning id into sh_mgr;
  insert into public.attendance_records(entity_id,location_id,employee_id,shift_id,clock_in_at) values (v_ent,a,e_col,sh_col,(y + time '09:05') at time zone 'Asia/Dubai') returning id into ar_col;
  insert into public.attendance_records(entity_id,location_id,employee_id,shift_id,clock_in_at) values (v_ent,a,e_col2,sh_col2,(y + time '10:00') at time zone 'Asia/Dubai') returning id into ar_col2;
  insert into public.attendance_records(entity_id,location_id,employee_id,shift_id,clock_in_at) values (v_ent,a,e_mgr,sh_mgr,(y + time '09:00') at time zone 'Asia/Dubai') returning id into ar_mgr;
  insert into public.attendance_records(entity_id,location_id,employee_id,clock_in_at) values (v_ent,a,e_nos,(y + time '12:00') at time zone 'Asia/Dubai') returning id into ar_nos;

  -- run 1 as the system (cron: no JWT)
  perform set_config('request.jwt.claims', '', true);
  r := public.run_nightly_payable_time(true);
  select count(*) into n from public.payable_shift_records where entity_id = v_ent;
  out := out || format('run1:%s payable=%s ', case when (r->>'failed_branches')::int = 0 then 'ok' else 'FAIL' end, n);
  select count(*) into n from public.clock_out_suggestions where entity_id = v_ent;
  out := out || format('sugg=%s ', n);
  select id, coalesce(to_char(suggested_clock_out_at at time zone 'Asia/Dubai','HH24:MI'),'null') into s_nos, v from public.clock_out_suggestions where attendance_record_id = ar_nos;
  out := out || 'no-shift-suggested=' || v || ' ';
  select id, to_char(suggested_clock_out_at at time zone 'Asia/Dubai','HH24:MI') into s_col, v from public.clock_out_suggestions where attendance_record_id = ar_col;
  out := out || 'col-suggested=' || coalesce(v,'null') || ' | ';
  select id into s_col2 from public.clock_out_suggestions where attendance_record_id = ar_col2;
  select id into s_mgr from public.clock_out_suggestions where attendance_record_id = ar_mgr;

  -- run 2: idempotent
  r := public.run_nightly_payable_time(true);
  select count(*) into n from public.payable_shift_records where entity_id = v_ent;
  out := out || format('run2:%s payable=%s seeded=%s ', case when (r->>'failed_branches')::int = 0 then 'ok' else 'FAIL' end, n,
    (select b2->>'seeded' from jsonb_array_elements(r->'branches') b2 where (b2->>'location_id')::uuid = a));
  select count(*) into n from public.clock_out_suggestions where entity_id = v_ent;
  out := out || format('sugg=%s | ', n);

  -- manager A
  perform set_config('request.jwt.claims', json_build_object('sub',u_mgr,'role','authenticated')::text, true);
  select count(*) into n from public.get_clock_out_suggestions(a); out := out || 'list-A=' || n || ' ';
  begin perform public.get_clock_out_suggestions(b); out := out || 'list-B:ALLOWED '; exception when others then out := out || 'list-B:refused '; end;

  -- manager of another branch
  perform set_config('request.jwt.claims', json_build_object('sub',u_mgrb,'role','authenticated')::text, true);
  begin perform public.confirm_clock_out_suggestion(s_col); out := out || 'confirm-B:ALLOWED '; exception when others then out := out || 'confirm-B:refused '; end;

  perform set_config('request.jwt.claims', json_build_object('sub',u_mgr,'role','authenticated')::text, true);
  begin perform public.confirm_clock_out_suggestion(s_mgr); out := out || 'confirm-own:ALLOWED '; exception when others then out := out || 'confirm-own:refused '; end;
  begin perform public.confirm_clock_out_suggestion(s_nos); out := out || 'confirm-noshift:ALLOWED '; exception when others then out := out || 'confirm-noshift:refused '; end;
  begin perform public.confirm_clock_out_suggestion(s_col); out := out || 'confirm:ok '; exception when others then out := out || 'confirm:FAIL(' || sqlerrm || ') '; end;
  select * into v_ar from public.attendance_records where id = ar_col;
  out := out || format('out=%s orig-in-kept=%s corrected=%s ', to_char(v_ar.clock_out_at at time zone 'Asia/Dubai','HH24:MI'),
    (v_ar.original_clock_in_at = v_ar.clock_in_at)::text, v_ar.corrected::text);
  select default_payable_minutes into n from public.payable_shift_records where shift_id = sh_col; out := out || 'payable=' || n || ' ';
  begin perform public.confirm_clock_out_suggestion(s_col); out := out || 'again:ALLOWED '; exception when others then out := out || 'again:refused '; end;

  perform set_config('request.jwt.claims', json_build_object('sub',u_mgrb,'role','authenticated')::text, true);
  begin perform public.dismiss_clock_out_suggestion(s_col2); out := out || 'dismiss-B:ALLOWED '; exception when others then out := out || 'dismiss-B:refused '; end;
  perform set_config('request.jwt.claims', json_build_object('sub',u_mgr,'role','authenticated')::text, true);
  begin perform public.dismiss_clock_out_suggestion(s_col2); out := out || 'dismiss:ok | '; exception when others then out := out || 'dismiss:FAIL(' || sqlerrm || ') | '; end;

  -- run 3: dismissed is not re-created, record still open
  perform set_config('request.jwt.claims', '', true);
  r := public.run_nightly_payable_time(true);
  select count(*) into n from public.clock_out_suggestions where entity_id = v_ent;
  out := out || format('run3:%s sugg=%s ', case when (r->>'failed_branches')::int = 0 then 'ok' else 'FAIL' end, n);
  select status into v from public.clock_out_suggestions where id = s_col2; out := out || 'dismissed-stays=' || v || ' ';
  perform set_config('request.jwt.claims', json_build_object('sub',u_mgr,'role','authenticated')::text, true);
  select count(*) into n from public.get_clock_out_suggestions(a); out := out || 'list-A=' || n || ' ';
  begin perform public.run_nightly_payable_time(true); out := out || 'system-only:ALLOWED'; exception when others then out := out || 'system-only:refused'; end;

  raise exception 'RESULT %', out;
end $$;
