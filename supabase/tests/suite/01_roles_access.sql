-- Suite 01: roles & row-level access on core tables.
-- Self-contained: builds throwaway entities/branches/people, reads each core table as every role
-- through RLS (role=authenticated / anon), then RAISEs 'RESULT ...' so NOTHING is kept.
-- Fixture: entity E1 (branches A, B) and E2 (branch C). Counts are always limited to E1+E2 rows,
-- so production data does not affect the result.
do $$
declare
  v_owner uuid := '045a3ad2-0cbe-4c5e-85bf-df27dd29e14f';
  e1 uuid; e2 uuid; la uuid; lb uuid; lc uuid; lt uuid;
  u_adm uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_sup uuid := gen_random_uuid();
  u_st uuid := gen_random_uuid(); u_rev uuid := gen_random_uuid();
  e_mgr uuid; e_sup uuid; e_st uuid; e_rev uuid; e_b uuid; e_c uuid;
  s_st uuid; s_draft uuid; s_b uuid;
  t date := (now() at time zone 'Asia/Dubai')::date;
  r text[] := '{}'; n int; n2 int; ents uuid[]; who text; uid uuid;
  exp_emp int; exp_sh int; exp_lr int; exp_ar int; exp_doc int; exp_nt int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.entities(name) values ('ZZ S01 E1') returning id into e1;
  insert into public.entities(name) values ('ZZ S01 E2') returning id into e2;
  ents := array[e1, e2];
  insert into public.locations(entity_id,name) values (e1,'ZZ A') returning id into la;
  insert into public.locations(entity_id,name) values (e1,'ZZ B') returning id into lb;
  insert into public.locations(entity_id,name) values (e2,'ZZ C') returning id into lc;
  insert into public.leave_types(entity_id,name,accrual_days_per_year,requires_approval) values (e1,'ZZ Annual',0,true) returning id into lt;
  insert into auth.users(id,email,aud,role) values
    (u_adm,'zz-s01-adm@example.invalid','authenticated','authenticated'),
    (u_mgr,'zz-s01-mgr@example.invalid','authenticated','authenticated'),
    (u_sup,'zz-s01-sup@example.invalid','authenticated','authenticated'),
    (u_st, 'zz-s01-st@example.invalid','authenticated','authenticated'),
    (u_rev,'zz-s01-rev@example.invalid','authenticated','authenticated');
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Mgr','active') returning id into e_mgr;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Sup','active') returning id into e_sup;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Staff','active') returning id into e_st;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Revoked','active') returning id into e_rev;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,lb,'ZZ AtB','active') returning id into e_b;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e2,lc,'ZZ AtC','active') returning id into e_c;
  perform public.admin_grant_access('zz-s01-adm@example.invalid','entity_admin',e1,null,null);
  perform public.admin_grant_access('zz-s01-mgr@example.invalid','location_manager',e1,la,e_mgr);
  perform public.admin_grant_access('zz-s01-sup@example.invalid','shift_supervisor',e1,la,e_sup);
  perform public.admin_grant_access('zz-s01-st@example.invalid','staff',e1,la,e_st);
  perform public.admin_grant_access('zz-s01-rev@example.invalid','staff',e1,la,e_rev);
  perform public.admin_revoke_access(u_rev, null, 'ZZ suite: revoked persona');

  -- data: shifts (published unless noted)
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,la,e_st,t+1,'09:00','17:00',true) returning id into s_st;
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,la,e_st,t+2,'09:00','17:00',false) returning id into s_draft;
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,la,e_sup,t+1,'09:00','17:00',true);
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,lb,e_b,t+1,'09:00','17:00',true) returning id into s_b;
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e2,lc,e_c,t+1,'09:00','17:00',true);
  -- leave (pending)
  insert into public.leave_requests(employee_id,leave_type_id,start_date,end_date,days_requested,status) values
    (e_st,lt,t+10,t+10,1,'pending'),(e_b,lt,t+10,t+10,1,'pending'),(e_c,lt,t+10,t+10,1,'pending');
  -- attendance
  insert into public.attendance_records(entity_id,location_id,employee_id,clock_in_at,clock_out_at) values
    (e1,la,e_st,now()-interval '30 hours',now()-interval '22 hours'),
    (e1,lb,e_b, now()-interval '30 hours',now()-interval '22 hours'),
    (e2,lc,e_c, now()-interval '30 hours',now()-interval '22 hours');
  -- documents (approved, confirmed). passport is a restricted type.
  insert into public.employee_documents(employee_id,doc_type,storage_path,review_status,is_current,upload_confirmed,uploaded_by,uploaded_at,submitted_by,submitted_at,reviewed_by,reviewed_at)
  select x.emp, x.dt::public.document_type, 'zz/s01/'||gen_random_uuid(), 'approved', true, true, v_owner, now(), v_owner, now(), v_owner, now()
  from (values (e_st,'health_card'),(e_st,'passport'),(e_b,'health_card'),(e_c,'health_card')) x(emp,dt);
  -- notifications
  insert into public.notifications(entity_id,recipient_user_id,employee_id,notification_type,title) values
    (e1,null,e_st,'zz_test','for staff'),(e1,u_mgr,null,'zz_test','for manager'),
    (e1,u_rev,null,'zz_test','for revoked'),(e2,null,e_c,'zz_test','for C');

  -- ===== every function used inside an RLS policy must be executable by the API role (else reads raise 'permission denied for function') =====
  select string_agg(distinct p.proname, ', ') into who
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and not has_function_privilege('authenticated', p.oid, 'execute')
     and exists (select 1 from pg_policies pol where pol.schemaname = 'public' and pol.roles::text ~ 'authenticated|public'
                   and (pol.qual ilike '%' || p.proname || '(%' or pol.with_check ilike '%' || p.proname || '(%'));
  r := r || (case when who is null then 'PASS ' else 'FAIL ' end || 'rls policies only call functions the API role can execute' || coalesce(' (not executable: ' || who || ')', ''))::text;

  -- ===== reads per role through RLS =====
  foreach who in array array['owner','entity_admin','location_manager','shift_supervisor','staff','revoked'] loop
    uid := case who when 'owner' then v_owner when 'entity_admin' then u_adm when 'location_manager' then u_mgr
                    when 'shift_supervisor' then u_sup when 'staff' then u_st else u_rev end;
    -- expected visible counts (E1+E2 fixture rows only)
    select a,b,c,d,e,f into exp_emp,exp_sh,exp_lr,exp_ar,exp_doc,exp_nt from (values
      ('owner',6,5,3,3,4,4),('entity_admin',5,4,2,2,3,3),('location_manager',4,3,1,1,1,1),
      ('shift_supervisor',1,1,0,0,0,0),('staff',1,1,1,1,2,1),('revoked',0,0,0,0,0,0)) v(k,a,b,c,d,e,f) where k = who;
    perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
    perform set_config('role','authenticated',true);
    select count(*) into n from public.employees where entity_id = any(ents);
    r := r || (case when n = exp_emp then 'PASS ' else 'FAIL ' end || format('rls %s sees %s/%s employees', who, n, exp_emp));
    begin
      select count(*) into n from public.shifts where entity_id = any(ents);
      r := r || (case when n = exp_sh then 'PASS ' else 'FAIL ' end || format('rls %s sees %s/%s shifts', who, n, exp_sh));
    exception when others then r := r || ('FAIL rls ' || who || ' reading shifts raised an error: ' || sqlerrm);
    end;
    select count(*) into n from public.leave_requests where employee_id in (e_st,e_b,e_c);
    r := r || (case when n = exp_lr then 'PASS ' else 'FAIL ' end || format('rls %s sees %s/%s leave_requests', who, n, exp_lr));
    select count(*) into n from public.attendance_records where entity_id = any(ents);
    r := r || (case when n = exp_ar then 'PASS ' else 'FAIL ' end || format('rls %s sees %s/%s attendance_records', who, n, exp_ar));
    select count(*) into n from public.employee_documents where employee_id in (e_mgr,e_sup,e_st,e_rev,e_b,e_c);
    r := r || (case when n = exp_doc then 'PASS ' else 'FAIL ' end || format('rls %s sees %s/%s employee_documents', who, n, exp_doc));
    select count(*) into n from public.notifications where entity_id = any(ents) and notification_type = 'zz_test';
    r := r || (case when n = exp_nt then 'PASS ' else 'FAIL ' end || format('rls %s sees %s/%s notifications', who, n, exp_nt));
    -- payroll_records (read-only, production rows): only owner (all) and accountant/payroll presets may read pay
    select count(*) into n from public.payroll_records;
    perform set_config('role','postgres',true);
    select count(*) into n2 from public.payroll_records;
    if who = 'owner' then
      r := r || (case when n = n2 then 'PASS ' else 'FAIL ' end || format('rls owner sees all %s/%s payroll_records', n, n2));
    else
      r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || format('rls %s sees %s payroll_records (expect 0)', who, n));
    end if;
  end loop;

  -- ===== targeted row checks =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  perform set_config('role','authenticated',true);
  begin
    select count(*) into n from public.shifts where id = s_draft;
    r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'rls staff cannot see own unpublished shift');
    select count(*) into n from public.shifts where id = s_b;
    r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'rls staff cannot see other branch shift');
  exception when others then r := r || ('FAIL rls staff reading shifts raised an error: ' || sqlerrm);
  end;
  begin update public.employees set notes = 'zz hacked' where id = e_st; get diagnostics n = row_count;
    r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'rls staff cannot update own employee row');
  exception when others then r := r || ('PASS rls staff cannot update own employee row (denied: ' || sqlstate || ')'); end;
  begin update public.leave_requests set status = 'approved' where employee_id = e_st; get diagnostics n = row_count;
    r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'rls staff cannot update own leave row');
  exception when others then r := r || ('PASS rls staff cannot update own leave row (denied: ' || sqlstate || ')'); end;
  begin update public.attendance_records set clock_out_at = now() where employee_id = e_st; get diagnostics n = row_count;
    r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'rls staff cannot update own attendance row');
  exception when others then r := r || ('PASS rls staff cannot update own attendance row (denied: ' || sqlstate || ')'); end;
  begin
    insert into public.leave_requests(employee_id,leave_type_id,start_date,end_date,days_requested,status) values (e_st,lt,t+20,t+20,1,'pending');
    raise exception 'zz_ok';
  exception when others then
    r := r || (case when sqlerrm = 'zz_ok' then 'PASS staff can submit own pending leave' else 'FAIL staff can submit own pending leave (' || sqlerrm || ')' end);
  end;
  begin
    insert into public.leave_requests(employee_id,leave_type_id,start_date,end_date,days_requested,status) values (e_st,lt,t+21,t+21,1,'approved');
    r := r || 'FAIL staff blocked from inserting own leave as approved (allowed)'::text;
  exception when others then r := r || 'PASS staff blocked from inserting own leave as approved'::text; end;
  begin
    insert into public.leave_requests(employee_id,leave_type_id,start_date,end_date,days_requested,status) values (e_b,lt,t+22,t+22,1,'pending');
    r := r || 'FAIL staff blocked from filing leave for a colleague (allowed)'::text;
  exception when others then r := r || 'PASS staff blocked from filing leave for a colleague'::text; end;
  begin
    insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time) values (e1,la,e_st,t+30,'09:00','12:00');
    r := r || 'FAIL staff blocked from creating shifts (allowed)'::text;
  exception when others then r := r || 'PASS staff blocked from creating shifts'::text; end;
  select count(*) into n from public.notifications where recipient_user_id = u_mgr;
  r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'rls staff cannot see manager notification');

  -- location manager writes
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin
    insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time) values (e1,la,e_st,t+30,'09:00','12:00');
    raise exception 'zz_ok';
  exception when others then
    r := r || (case when sqlerrm = 'zz_ok' then 'PASS manager can create shift at own branch' else 'FAIL manager can create shift at own branch (' || sqlerrm || ')' end);
  end;
  begin
    insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time) values (e1,lb,e_b,t+30,'09:00','12:00');
    r := r || 'FAIL manager blocked from creating shift at other branch (allowed)'::text;
  exception when others then r := r || 'PASS manager blocked from creating shift at other branch'::text; end;
  begin update public.employees set notes = 'zz' where id = e_b; get diagnostics n = row_count;
    r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'rls manager cannot update other-branch employee');
  exception when others then r := r || ('PASS rls manager cannot update other-branch employee (denied: ' || sqlstate || ')'); end;
  select count(*) into n from public.employee_documents where employee_id = e_st and doc_type = 'passport';
  r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'rls manager cannot see restricted (passport) document');

  -- entity admin cross-entity
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  begin update public.employees set notes = 'zz' where id = e_c; get diagnostics n = row_count;
    r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'rls entity_admin cannot update other-entity employee');
  exception when others then r := r || ('PASS rls entity_admin cannot update other-entity employee (denied: ' || sqlstate || ')'); end;
  begin
    insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time) values (e2,lc,e_c,t+30,'09:00','12:00');
    r := r || 'FAIL entity_admin blocked from creating shift in other entity (allowed)'::text;
  exception when others then r := r || 'PASS entity_admin blocked from creating shift in other entity'::text; end;

  -- revoked user: RPC access
  perform set_config('request.jwt.claims', json_build_object('sub', u_rev, 'role', 'authenticated')::text, true);
  r := r || (case when public.my_role() is null and public.my_employee_id() is null then 'PASS ' else 'FAIL ' end || 'revoked user has no role / employee link');
  begin
    insert into public.leave_requests(employee_id,leave_type_id,start_date,end_date,days_requested,status) values (e_rev,lt,t+23,t+23,1,'pending');
    r := r || 'FAIL revoked user blocked from submitting leave (allowed)'::text;
  exception when others then r := r || 'PASS revoked user blocked from submitting leave'::text; end;

  -- anon
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('role','anon',true);
  foreach who in array array['employees','shifts','leave_requests','attendance_records','employee_documents','payroll_records','notifications'] loop
    begin
      execute format('select count(*) from public.%I', who) into n;
      r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || format('anon sees %s rows in %s', n, who));
    exception when others then r := r || format('PASS anon denied on %s', who); end;
  end loop;
  foreach who in array array['approve_leave_request(gen_random_uuid(),''approve'')','correct_attendance_record(gen_random_uuid(),null,now(),''x'')',
                            'transfer_employee(gen_random_uuid(),gen_random_uuid(),current_date,''x'')','stage_document_upload(gen_random_uuid(),''other'',''pdf'')'] loop
    begin
      execute 'select public.' || who;
      r := r || format('FAIL anon cannot execute %s (allowed)', split_part(who, '(', 1));
    exception when others then
      r := r || (case when sqlstate = '42501' then 'PASS ' else 'FAIL ' end || format('anon cannot execute %s (%s)', split_part(who, '(', 1), sqlstate));
    end;
  end loop;
  perform set_config('role','postgres',true);

  raise exception 'RESULT suite01 pass=% fail=% :: %',
    (select count(*) from unnest(r) x where x like 'PASS%'), (select count(*) from unnest(r) x where x like 'FAIL%'),
    array_to_string(r, '; ');
end $$;
