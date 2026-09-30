-- Suite 04: attendance correction rules (correct_attendance_record + self-correction guard).
-- Self-contained; the final RAISE 'RESULT ...' rolls back everything.
do $$
declare
  v_owner uuid := '045a3ad2-0cbe-4c5e-85bf-df27dd29e14f';
  e1 uuid; e2 uuid; la uuid; lb uuid; lc uuid;
  u_adm uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_mgrb uuid := gen_random_uuid(); u_mgrx uuid := gen_random_uuid();
  u_sup uuid := gen_random_uuid(); u_st uuid := gen_random_uuid(); u_none uuid := gen_random_uuid();
  e_mgr uuid; e_mgrb uuid; e_mgrx uuid; e_sup uuid; e_st uuid; e_st2 uuid; e_b uuid; e_c uuid;
  ar_st uuid; ar_open uuid; ar_mgr uuid; ar_sup uuid; ar_b uuid; ar_c uuid;
  orig_in timestamptz := date_trunc('minute', now()) - interval '30 hours';
  orig_out timestamptz := date_trunc('minute', now()) - interval '22 hours';
  r text[] := '{}'; n int; a public.attendance_records;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.entities(name) values ('ZZ S04 E1') returning id into e1;
  insert into public.entities(name) values ('ZZ S04 E2') returning id into e2;
  insert into public.locations(entity_id,name) values (e1,'ZZ A') returning id into la;
  insert into public.locations(entity_id,name) values (e1,'ZZ B') returning id into lb;
  insert into public.locations(entity_id,name) values (e2,'ZZ C') returning id into lc;
  insert into auth.users(id,email,aud,role) values
    (u_adm,'zz-s04-adm@example.invalid','authenticated','authenticated'),(u_mgr,'zz-s04-mgr@example.invalid','authenticated','authenticated'),
    (u_mgrb,'zz-s04-mgrb@example.invalid','authenticated','authenticated'),(u_mgrx,'zz-s04-mgrx@example.invalid','authenticated','authenticated'),
    (u_sup,'zz-s04-sup@example.invalid','authenticated','authenticated'),(u_st,'zz-s04-st@example.invalid','authenticated','authenticated'),
    (u_none,'zz-s04-none@example.invalid','authenticated','authenticated');  -- signed-up login with no access grant / profile
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Mgr','active') returning id into e_mgr;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,lb,'ZZ MgrB','active') returning id into e_mgrb;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ MgrRevoked','active') returning id into e_mgrx;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Sup','active') returning id into e_sup;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ St','active') returning id into e_st;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ St2','active') returning id into e_st2;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,lb,'ZZ AtB','active') returning id into e_b;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e2,lc,'ZZ AtC','active') returning id into e_c;
  perform public.admin_grant_access('zz-s04-adm@example.invalid','entity_admin',e1,null,null);
  perform public.admin_grant_access('zz-s04-mgr@example.invalid','location_manager',e1,la,e_mgr);
  perform public.admin_grant_access('zz-s04-mgrb@example.invalid','location_manager',e1,lb,e_mgrb);
  perform public.admin_grant_access('zz-s04-mgrx@example.invalid','location_manager',e1,la,e_mgrx);
  perform public.admin_grant_access('zz-s04-sup@example.invalid','shift_supervisor',e1,la,e_sup);
  perform public.admin_grant_access('zz-s04-st@example.invalid','staff',e1,la,e_st);
  perform public.admin_revoke_access(u_mgrx, null, 'ZZ suite: revoked manager');
  insert into public.attendance_records(entity_id,location_id,employee_id,clock_in_at,clock_out_at) values (e1,la,e_st,orig_in,orig_out) returning id into ar_st;
  insert into public.attendance_records(entity_id,location_id,employee_id,clock_in_at) values (e1,la,e_st2,orig_in) returning id into ar_open;
  insert into public.attendance_records(entity_id,location_id,employee_id,clock_in_at,clock_out_at) values (e1,la,e_mgr,orig_in,orig_out) returning id into ar_mgr;
  insert into public.attendance_records(entity_id,location_id,employee_id,clock_in_at,clock_out_at) values (e1,la,e_sup,orig_in,orig_out) returning id into ar_sup;
  insert into public.attendance_records(entity_id,location_id,employee_id,clock_in_at,clock_out_at) values (e1,lb,e_b,orig_in,orig_out) returning id into ar_b;
  insert into public.attendance_records(entity_id,location_id,employee_id,clock_in_at,clock_out_at) values (e2,lc,e_c,orig_in,orig_out) returning id into ar_c;

  perform set_config('role','authenticated',true);
  -- staff
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  begin perform public.correct_attendance_record(ar_st, null, orig_out + interval '1 hour', 'my own'); r := r || 'FAIL att: staff cannot correct own record (allowed)'::text;
  exception when others then r := r || 'PASS att: staff cannot correct own record'::text; end;
  begin perform public.correct_attendance_record(ar_open, null, orig_in + interval '8 hours', 'colleague'); r := r || 'FAIL att: staff cannot correct a colleague (allowed)'::text;
  exception when others then r := r || 'PASS att: staff cannot correct a colleague'::text; end;

  -- manager A
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin perform public.correct_attendance_record(ar_st, null, orig_out + interval '1 hour', '   '); r := r || 'FAIL att: blank reason refused (allowed)'::text;
  exception when others then r := r || (case when sqlerrm ilike '%reason is required%' then 'PASS ' else 'FAIL ' end || 'att: blank reason refused (' || sqlerrm || ')'); end;
  begin perform public.correct_attendance_record(ar_st, null, orig_in - interval '1 hour', 'backwards'); r := r || 'FAIL att: clock-out before clock-in refused (allowed)'::text;
  exception when others then r := r || 'PASS att: clock-out before clock-in refused'::text; end;
  begin perform public.correct_attendance_record(ar_st, null, now() + interval '2 hours', 'future'); r := r || 'FAIL att: future time refused (allowed)'::text;
  exception when others then r := r || 'PASS att: future time refused'::text; end;
  begin perform public.correct_attendance_record(ar_st, orig_in, orig_out, 'no-op'); r := r || 'FAIL att: no-op correction refused (allowed)'::text;
  exception when others then r := r || 'PASS att: no-op correction refused'::text; end;
  begin perform public.correct_attendance_record(ar_st, null, orig_out + interval '1 hour', '  forgot to clock out  ');
    r := r || 'PASS att: manager corrects branch record'::text;
  exception when others then r := r || ('FAIL att: manager corrects branch record (' || sqlerrm || ')'); end;
  begin perform public.correct_attendance_record(ar_st, orig_in - interval '30 minutes', null, 'came early');
    r := r || 'PASS att: second correction allowed'::text;
  exception when others then r := r || ('FAIL att: second correction allowed (' || sqlerrm || ')'); end;
  begin perform public.correct_attendance_record(ar_mgr, null, orig_out + interval '1 hour', 'me'); r := r || 'FAIL att: manager cannot correct own record (allowed)'::text;
  exception when others then r := r || 'PASS att: manager cannot correct own record'::text; end;
  begin perform public.correct_attendance_record(ar_b, null, orig_out + interval '1 hour', 'B'); r := r || 'FAIL att: manager cannot correct other branch (allowed)'::text;
  exception when others then r := r || 'PASS att: manager cannot correct other branch'::text; end;
  perform set_config('role','postgres',true);
  select * into a from public.attendance_records where id = ar_st;
  r := r || (case when a.corrected and a.corrected_by = u_mgr and a.correction_reason = 'came early' then 'PASS ' else 'FAIL ' end || 'att: corrected flag, corrected_by and trimmed reason stored');
  r := r || (case when a.original_clock_in_at = orig_in and a.original_clock_out_at = orig_out and a.clock_in_at = orig_in - interval '30 minutes' and a.clock_out_at = orig_out + interval '1 hour'
             then 'PASS ' else 'FAIL ' end || 'att: first originals preserved across two corrections');
  select count(*) into n from public.audit_log where record_id = ar_st and action = 'attendance_corrected';
  r := r || (case when n = 2 then 'PASS ' else 'FAIL ' end || format('att: each correction audited (%s)', n));
  perform set_config('role','authenticated',true);

  -- supervisor A
  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  begin perform public.correct_attendance_record(ar_open, null, orig_in + interval '8 hours', 'closed open shift');
    r := r || 'PASS att: supervisor closes a colleague''s open record'::text;
  exception when others then r := r || ('FAIL att: supervisor closes a colleague''s open record (' || sqlerrm || ')'); end;
  begin perform public.correct_attendance_record(ar_sup, null, orig_out + interval '1 hour', 'me'); r := r || 'FAIL att: supervisor cannot correct own record (allowed)'::text;
  exception when others then r := r || 'PASS att: supervisor cannot correct own record'::text; end;
  begin perform public.correct_attendance_record(ar_b, null, orig_out + interval '1 hour', 'B'); r := r || 'FAIL att: supervisor cannot correct other branch (allowed)'::text;
  exception when others then r := r || 'PASS att: supervisor cannot correct other branch'::text; end;

  -- other-branch manager, revoked manager
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgrb, 'role', 'authenticated')::text, true);
  begin perform public.correct_attendance_record(ar_st, null, orig_out + interval '2 hours', 'x'); r := r || 'FAIL att: other-branch manager refused (allowed)'::text;
  exception when others then r := r || 'PASS att: other-branch manager refused'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgrx, 'role', 'authenticated')::text, true);
  begin perform public.correct_attendance_record(ar_st, null, orig_out + interval '2 hours', 'x'); r := r || 'FAIL att: revoked manager refused (allowed)'::text;
  exception when others then r := r || 'PASS att: revoked manager refused'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_none, 'role', 'authenticated')::text, true);
  begin perform public.correct_attendance_record(ar_c, null, orig_out + interval '3 hours', 'x'); r := r || 'FAIL att: login without any profile refused (allowed)'::text;
  exception when others then r := r || 'PASS att: login without any profile refused'::text; end;

  -- entity admin: any branch of own entity, not other entity
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  begin perform public.correct_attendance_record(ar_b, null, orig_out + interval '1 hour', 'admin fix'); r := r || 'PASS att: entity admin corrects any own-entity branch'::text;
  exception when others then r := r || ('FAIL att: entity admin corrects any own-entity branch (' || sqlerrm || ')'); end;
  begin perform public.correct_attendance_record(ar_c, null, orig_out + interval '1 hour', 'x'); r := r || 'FAIL att: entity admin refused for other entity (allowed)'::text;
  exception when others then r := r || 'PASS att: entity admin refused for other entity'::text; end;
  -- owner: anywhere
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin perform public.correct_attendance_record(ar_c, null, orig_out + interval '1 hour', 'owner fix'); r := r || 'PASS att: owner corrects any entity'::text;
  exception when others then r := r || ('FAIL att: owner corrects any entity (' || sqlerrm || ')'); end;
  perform set_config('role','postgres',true);

  raise exception 'RESULT suite04 pass=% fail=% :: %',
    (select count(*) from unnest(r) x where x like 'PASS%'), (select count(*) from unnest(r) x where x like 'FAIL%'),
    array_to_string(r, '; ');
end $$;
