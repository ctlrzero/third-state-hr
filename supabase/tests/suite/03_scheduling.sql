-- Suite 03: scheduling - validate_shift overlap rules, publish_schedule_period, adjust_published_shift
-- (reason required), shift swaps (request / claim / approve), report_absence, shift offers
-- (send_shift_offer / respond_shift_offer). Self-contained; the final RAISE 'RESULT ...' rolls back everything.
do $$
declare
  v_owner uuid := '045a3ad2-0cbe-4c5e-85bf-df27dd29e14f';
  e1 uuid; la uuid; lb uuid; lt uuid;
  u_mgr uuid := gen_random_uuid(); u_mgrb uuid := gen_random_uuid(); u_sup uuid := gen_random_uuid();
  u_st uuid := gen_random_uuid(); u_st2 uuid := gen_random_uuid(); u_st3 uuid := gen_random_uuid(); u_stb uuid := gen_random_uuid();
  u_mgrx uuid := gen_random_uuid(); u_none uuid := gen_random_uuid(); e_mgrx uuid;
  e_mgr uuid; e_mgrb uuid; e_sup uuid; e_st uuid; e_st2 uuid; e_st3 uuid; e_stb uuid;
  sh1 uuid; sh_night uuid; sh_swap uuid; sh_abs uuid; sh_leave uuid; sh_b uuid; sh_draft uuid; sh_past uuid; sh_d2 uuid;
  sw uuid; o_st uuid; o_st2 uuid;
  t date := (now() at time zone 'Asia/Dubai')::date;
  r text[] := '{}'; n int; res jsonb; st text; v_x uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.entities(name) values ('ZZ S03') returning id into e1;
  insert into public.locations(entity_id,name) values (e1,'ZZ A') returning id into la;
  insert into public.locations(entity_id,name) values (e1,'ZZ B') returning id into lb;
  insert into public.leave_types(entity_id,name,accrual_days_per_year,requires_approval) values (e1,'ZZ Sick',10,true) returning id into lt;
  insert into auth.users(id,email,aud,role) values
    (u_mgr,'zz-s03-mgr@example.invalid','authenticated','authenticated'),(u_mgrb,'zz-s03-mgrb@example.invalid','authenticated','authenticated'),
    (u_sup,'zz-s03-sup@example.invalid','authenticated','authenticated'),(u_st,'zz-s03-st@example.invalid','authenticated','authenticated'),
    (u_st2,'zz-s03-st2@example.invalid','authenticated','authenticated'),(u_st3,'zz-s03-st3@example.invalid','authenticated','authenticated'),
    (u_stb,'zz-s03-stb@example.invalid','authenticated','authenticated'),(u_mgrx,'zz-s03-mgrx@example.invalid','authenticated','authenticated'),
    (u_none,'zz-s03-none@example.invalid','authenticated','authenticated');  -- u_none: login with no profile
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Mgr','active') returning id into e_mgr;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,lb,'ZZ MgrB','active') returning id into e_mgrb;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Sup','active') returning id into e_sup;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ St','active') returning id into e_st;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ St2','active') returning id into e_st2;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ St3','active') returning id into e_st3;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,lb,'ZZ StB','active') returning id into e_stb;
  perform public.admin_grant_access('zz-s03-mgr@example.invalid','location_manager',e1,la,e_mgr);
  perform public.admin_grant_access('zz-s03-mgrb@example.invalid','location_manager',e1,lb,e_mgrb);
  perform public.admin_grant_access('zz-s03-sup@example.invalid','shift_supervisor',e1,la,e_sup);
  perform public.admin_grant_access('zz-s03-st@example.invalid','staff',e1,la,e_st);
  perform public.admin_grant_access('zz-s03-st2@example.invalid','staff',e1,la,e_st2);
  perform public.admin_grant_access('zz-s03-st3@example.invalid','staff',e1,la,e_st3);
  perform public.admin_grant_access('zz-s03-stb@example.invalid','staff',e1,lb,e_stb);
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ MgrRevoked','active') returning id into e_mgrx;
  perform public.admin_grant_access('zz-s03-mgrx@example.invalid','location_manager',e1,la,e_mgrx);
  perform public.admin_revoke_access(u_mgrx, null, 'ZZ suite: revoked manager');

  -- ===== validate_shift (manager builds drafts through the API role; note shifts.is_published defaults to TRUE) =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  perform set_config('role','authenticated',true);
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,la,e_st,t+3,'09:00','17:00',false) returning id into sh1;
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,la,e_st,t+4,'22:00','06:00',false) returning id into sh_night;
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,la,e_st,t+6,'09:00','17:00',false) returning id into sh_swap;
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,la,e_st3,t+4,'09:00','17:00',false) returning id into sh_abs;
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,la,e_st3,t+8,'09:00','17:00',false) returning id into sh_leave;
  begin insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time) values (e1,la,e_st,t+3,'12:00','20:00');
    r := r || 'FAIL shift: overlapping shift for same person refused (allowed)'::text;
  exception when others then r := r || (case when sqlerrm ilike '%overlaps%' then 'PASS ' else 'FAIL ' end || 'shift: overlapping shift for same person refused (' || sqlerrm || ')'); end;
  begin insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time) values (e1,la,e_st,t+5,'05:00','10:00');
    r := r || 'FAIL shift: overlap with previous overnight shift refused (allowed)'::text;
  exception when others then r := r || (case when sqlerrm ilike '%overlaps%' then 'PASS ' else 'FAIL ' end || 'shift: overlap with previous overnight shift refused (' || sqlerrm || ')'); end;
  begin insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time) values (e1,la,e_st,t+3,'17:00','21:00'); raise exception 'zz_ok';
  exception when others then r := r || (case when sqlerrm = 'zz_ok' then 'PASS ' else 'FAIL ' end || 'shift: back-to-back (touching) shift allowed (' || sqlerrm || ')'); end;
  begin insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time) values (e1,la,e_st2,t+3,'09:00','09:00');
    r := r || 'FAIL shift: zero-length shift refused (allowed)'::text;
  exception when others then r := r || 'PASS shift: zero-length shift refused'::text; end;
  begin insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,break_minutes) values (e1,la,e_st2,t+3,'09:00','10:00',60);
    r := r || 'FAIL shift: break as long as the shift refused (allowed)'::text;
  exception when others then r := r || 'PASS shift: break as long as the shift refused'::text; end;
  begin
    insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,status) values (e1,la,e_st2,t+3,'09:00','17:00','cancelled');
    insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time) values (e1,la,e_st2,t+3,'09:00','17:00'); raise exception 'zz_ok';
  exception when others then r := r || (case when sqlerrm = 'zz_ok' then 'PASS ' else 'FAIL ' end || 'shift: cancelled shift does not block the slot (' || sqlerrm || ')'); end;
  perform set_config('role','postgres',true);
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,lb,e_stb,t+3,'09:00','17:00',false) returning id into sh_b;
  insert into public.leave_requests(employee_id,leave_type_id,start_date,end_date,days_requested,status,decided_by,decided_at) values (e_st3,lt,t+8,t+8,1,'approved',v_owner,now());

  -- ===== publish_schedule_period =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  perform set_config('role','authenticated',true);
  begin perform public.publish_schedule_period(la, t, t+14); r := r || 'FAIL publish: staff cannot publish (allowed)'::text;
  exception when others then r := r || 'PASS publish: staff cannot publish'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgrb, 'role', 'authenticated')::text, true);
  begin perform public.publish_schedule_period(la, t, t+14); r := r || 'FAIL publish: other-branch manager cannot publish (allowed)'::text;
  exception when others then r := r || 'PASS publish: other-branch manager cannot publish'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin perform public.publish_schedule_period(la, t+14, t); r := r || 'FAIL publish: end before start refused (allowed)'::text;
  exception when others then r := r || 'PASS publish: end before start refused'::text; end;
  res := public.publish_schedule_period(la, t, t+14);
  r := r || (case when (res->>'published')::int = 4 and jsonb_array_length(res->'skipped_leave') = 1 then 'PASS ' else 'FAIL ' end
             || format('publish: manager publishes 4 drafts and skips 1 on approved leave (%s)', res));
  perform set_config('role','postgres',true);
  r := r || (case when not (select is_published from public.shifts where id = sh_leave) then 'PASS ' else 'FAIL ' end || 'publish: shift on approved leave stays draft');
  r := r || (case when not (select is_published from public.shifts where id = sh_b) then 'PASS ' else 'FAIL ' end || 'publish: other branch drafts untouched');
  select count(*) into n from public.audit_log where record_id = la and action = 'schedule_shifts_published';
  r := r || (case when n >= 1 then 'PASS ' else 'FAIL ' end || 'publish: audited');

  -- ===== adjust_published_shift =====
  perform set_config('role','authenticated',true);
  begin update public.shifts set end_time = '19:00' where id = sh1; r := r || 'FAIL adjust: direct edit of a published shift without reason refused (allowed)'::text;
  exception when others then r := r || 'PASS adjust: direct edit of a published shift without reason refused'::text; end;
  begin perform public.adjust_published_shift(sh1, '   ', null, null, '18:00'); r := r || 'FAIL adjust: blank reason refused (allowed)'::text;
  exception when others then r := r || (case when sqlerrm ilike '%reason is required%' then 'PASS ' else 'FAIL ' end || 'adjust: blank reason refused (' || sqlerrm || ')'); end;
  begin perform public.adjust_published_shift(sh1, 'ZZ longer day', null, null, '18:00');
    r := r || 'PASS adjust: manager adjusts with reason'::text;
  exception when others then r := r || ('FAIL adjust: manager adjusts with reason (' || sqlerrm || ')'); end;
  begin perform public.adjust_published_shift(sh_night, 'ZZ move', t+3, '10:00', '14:00'); r := r || 'FAIL adjust: adjusting into an overlap refused (allowed)'::text;
  exception when others then r := r || (case when sqlerrm ilike '%overlaps%' then 'PASS ' else 'FAIL ' end || 'adjust: adjusting into an overlap refused (' || sqlerrm || ')'); end;
  begin perform public.adjust_published_shift(sh_leave, 'ZZ draft', null, null, '18:00'); r := r || 'FAIL adjust: draft shift must be edited directly (allowed)'::text;
  exception when others then r := r || 'PASS adjust: draft shift must be edited directly'::text; end;
  begin perform public.adjust_published_shift(sh_b, 'ZZ other branch', null, null, '18:00'); r := r || 'FAIL adjust: manager cannot adjust other-branch shift (allowed)'::text;
  exception when others then r := r || 'PASS adjust: manager cannot adjust other-branch shift'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  begin perform public.adjust_published_shift(sh1, 'ZZ me', null, null, '12:00'); r := r || 'FAIL adjust: staff cannot adjust (allowed)'::text;
  exception when others then r := r || 'PASS adjust: staff cannot adjust'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  begin perform public.adjust_published_shift(sh1, 'ZZ sup time', null, null, '20:00'); r := r || 'FAIL adjust: supervisor cannot change times (allowed)'::text;
  exception when others then r := r || 'PASS adjust: supervisor cannot change times'::text; end;
  -- revoked manager / login without profile (success is rolled back via 'zz_allowed')
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgrx, 'role', 'authenticated')::text, true);
  begin perform public.adjust_published_shift(sh1, 'ZZ revoked', null, null, '20:00'); raise exception 'zz_allowed';
  exception when others then r := r || (case when sqlerrm = 'zz_allowed' then 'FAIL ' else 'PASS ' end || 'adjust: revoked manager cannot adjust'); end;
  begin perform public.cancel_published_shift(sh1, 'ZZ revoked'); raise exception 'zz_allowed';
  exception when others then r := r || (case when sqlerrm = 'zz_allowed' then 'FAIL ' else 'PASS ' end || 'adjust: revoked manager cannot cancel a published shift'); end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_none, 'role', 'authenticated')::text, true);
  begin perform public.adjust_published_shift(sh1, 'ZZ nobody', null, null, '20:00'); raise exception 'zz_allowed';
  exception when others then r := r || (case when sqlerrm = 'zz_allowed' then 'FAIL ' else 'PASS ' end || 'adjust: login without profile cannot adjust'); end;
  begin perform public.cancel_published_shift(sh1, 'ZZ nobody'); raise exception 'zz_allowed';
  exception when others then r := r || (case when sqlerrm = 'zz_allowed' then 'FAIL ' else 'PASS ' end || 'adjust: login without profile cannot cancel a published shift'); end;
  perform set_config('role','postgres',true);
  select count(*) into n from public.shift_adjustments where shift_id = sh1 and reason = 'ZZ longer day' and change_type = 'time_changed';
  r := r || (case when n = 1 and (select end_time from public.shifts where id = sh1) = '18:00' then 'PASS ' else 'FAIL ' end || 'adjust: change applied and logged with reason in shift_adjustments');

  -- ===== shift swaps =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_st2, 'role', 'authenticated')::text, true);
  perform set_config('role','authenticated',true);
  begin perform public.request_shift_swap(sh_swap, 'not mine'); r := r || 'FAIL swap: cannot request swap on someone else''s shift (allowed)'::text;
  exception when others then r := r || 'PASS swap: cannot request swap on someone else''s shift'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  begin sw := public.request_shift_swap(sh_swap, 'ZZ dentist'); r := r || 'PASS swap: staff requests swap on own published shift'::text;
  exception when others then r := r || ('FAIL swap: staff requests swap on own published shift (' || sqlerrm || ')'); end;
  begin perform public.request_shift_swap(sh_swap, 'again'); r := r || 'FAIL swap: duplicate open swap refused (allowed)'::text;
  exception when others then r := r || 'PASS swap: duplicate open swap refused'::text; end;
  begin perform public.claim_shift_swap(sw); r := r || 'FAIL swap: requester cannot claim own swap (allowed)'::text;
  exception when others then r := r || 'PASS swap: requester cannot claim own swap'::text; end;
  perform set_config('role','postgres',true);
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,la,e_st,t+11,'09:00','17:00',false) returning id into sh_d2;
  perform set_config('role','authenticated',true);
  begin v_x := public.request_shift_swap(sh_d2, 'draft'); r := r || 'FAIL swap: cannot request swap on an unpublished (draft) shift (allowed)'::text;
  exception when others then r := r || 'PASS swap: cannot request swap on an unpublished (draft) shift'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_stb, 'role', 'authenticated')::text, true);
  begin perform public.claim_shift_swap(sw); r := r || 'FAIL swap: other-branch staff cannot claim (cross-outlet off) (allowed)'::text;
  exception when others then r := r || 'PASS swap: other-branch staff cannot claim (cross-outlet off)'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_st2, 'role', 'authenticated')::text, true);
  begin perform public.claim_shift_swap(sw); r := r || 'PASS swap: colleague claims'::text;
  exception when others then r := r || ('FAIL swap: colleague claims (' || sqlerrm || ')'); end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_st3, 'role', 'authenticated')::text, true);
  begin perform public.approve_shift_swap(sw, 'approve'); r := r || 'FAIL swap: staff cannot approve swap (allowed)'::text;
  exception when others then r := r || 'PASS swap: staff cannot approve swap'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgrb, 'role', 'authenticated')::text, true);
  begin perform public.approve_shift_swap(sw, 'approve'); r := r || 'FAIL swap: other-branch manager cannot approve (allowed)'::text;
  exception when others then r := r || 'PASS swap: other-branch manager cannot approve'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin perform public.approve_shift_swap(sw, 'approve'); r := r || 'PASS swap: manager approves'::text;
  exception when others then r := r || ('FAIL swap: manager approves (' || sqlerrm || ')'); end;
  perform set_config('role','postgres',true);
  select status into st from public.shift_swap_requests where id = sw;
  r := r || (case when st = 'approved' and (select employee_id from public.shifts where id = sh_swap) = e_st2 then 'PASS ' else 'FAIL ' end || format('swap: shift moved to claimant, status=%s', st));
  select count(*) into n from public.notifications where target_id = sw and notification_type = 'swap_approved';
  r := r || (case when n = 2 then 'PASS ' else 'FAIL ' end || format('swap: requester and claimant notified (%s)', n));
  select count(*) into n from public.shift_adjustments where shift_id = sh_swap and change_type = 'reassigned' and reason = 'Shift swap approved';
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'swap: reassignment logged');

  -- ===== report_absence =====
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,la,e_st3,t+10,'09:00','17:00',false) returning id into sh_draft;
  insert into public.shifts(entity_id,location_id,employee_id,shift_date,start_time,end_time,is_published) values (e1,la,e_st3,t-1,'09:00','17:00',true) returning id into sh_past;
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  perform set_config('role','authenticated',true);
  begin perform public.report_absence(sh_abs, lt, 'not mine'); r := r || 'FAIL absence: cannot report for someone else''s shift (allowed)'::text;
  exception when others then r := r || 'PASS absence: cannot report for someone else''s shift'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_st3, 'role', 'authenticated')::text, true);
  begin perform public.report_absence(sh_draft, lt, 'draft'); r := r || 'FAIL absence: cannot report for a draft shift (allowed)'::text;
  exception when others then r := r || 'PASS absence: cannot report for a draft shift'::text; end;
  begin perform public.report_absence(sh_past, lt, 'past'); r := r || 'FAIL absence: cannot report for a past shift (allowed)'::text;
  exception when others then r := r || 'PASS absence: cannot report for a past shift'::text; end;
  begin
    res := public.report_absence(sh_abs, lt, 'ZZ fever');
    r := r || (case when (res->>'managers_notified')::int = 2 then 'PASS ' else 'FAIL ' end || format('absence: reported, manager+supervisor notified (%s)', res->>'managers_notified'));
  exception when others then r := r || ('FAIL absence: reported (' || sqlerrm || ')'); end;
  begin perform public.report_absence(sh_abs, lt, 'again'); r := r || 'FAIL absence: second report for same day refused (allowed)'::text;
  exception when others then r := r || 'PASS absence: second report for same day refused'::text; end;
  perform set_config('role','postgres',true);
  select count(*) into n from public.leave_requests where employee_id = e_st3 and status = 'pending' and start_date = t+4 and end_date = t+4;
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'absence: pending 1-day leave request created');
  select count(*) into n from public.shift_adjustments where shift_id = sh_abs and change_type = 'absence_reported';
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'absence: logged in shift_adjustments');

  -- ===== shift offers (cover for sh_abs held by e_st3) =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  perform set_config('role','authenticated',true);
  begin perform public.send_shift_offer(sh_abs, array[e_st2], 'cover?'); r := r || 'FAIL offer: staff cannot send offers (allowed)'::text;
  exception when others then r := r || 'PASS offer: staff cannot send offers'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgrb, 'role', 'authenticated')::text, true);
  begin perform public.send_shift_offer(sh_abs, array[e_st2], 'cover?'); r := r || 'FAIL offer: other-branch manager cannot send offers (allowed)'::text;
  exception when others then r := r || 'PASS offer: other-branch manager cannot send offers'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin perform public.send_shift_offer(sh_leave, array[e_st2], 'draft'); r := r || 'FAIL offer: draft shift cannot be offered (allowed)'::text;
  exception when others then r := r || 'PASS offer: draft shift cannot be offered'::text; end;
  begin
    res := public.send_shift_offer(sh_abs, array[e_st2, e_st, e_st3], 'ZZ can you cover?');
    r := r || (case when jsonb_array_length(res->'sent') = 2 and jsonb_array_length(res->'skipped') = 1 then 'PASS ' else 'FAIL ' end
               || format('offer: sent to 2 eligible, current holder skipped (%s)', res));
  exception when others then r := r || ('FAIL offer: manager sends offers (' || sqlerrm || ')'); end;
  perform set_config('role','postgres',true);
  select id into o_st from public.shift_offers where shift_id = sh_abs and employee_id = e_st;
  select id into o_st2 from public.shift_offers where shift_id = sh_abs and employee_id = e_st2;
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  perform set_config('role','authenticated',true);
  begin perform public.respond_shift_offer(o_st2, true); r := r || 'FAIL offer: cannot answer someone else''s offer (allowed)'::text;
  exception when others then r := r || 'PASS offer: cannot answer someone else''s offer'::text; end;
  begin res := public.respond_shift_offer(o_st, false);
    r := r || (case when res->>'status' = 'declined' then 'PASS ' else 'FAIL ' end || 'offer: recipient declines');
  exception when others then r := r || ('FAIL offer: recipient declines (' || sqlerrm || ')'); end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_st2, 'role', 'authenticated')::text, true);
  begin res := public.respond_shift_offer(o_st2, true);
    r := r || (case when res->>'status' = 'accepted' then 'PASS ' else 'FAIL ' end || format('offer: recipient accepts (%s)', res));
  exception when others then r := r || ('FAIL offer: recipient accepts (' || sqlerrm || ')'); end;
  begin perform public.respond_shift_offer(o_st2, true); r := r || 'FAIL offer: answered offer cannot be answered again (allowed)'::text;
  exception when others then r := r || 'PASS offer: answered offer cannot be answered again'::text; end;
  perform set_config('role','postgres',true);
  r := r || (case when (select employee_id from public.shifts where id = sh_abs) = e_st2 then 'PASS ' else 'FAIL ' end || 'offer: accepted offer reassigns the shift');
  select count(*) into n from public.notifications where employee_id = e_st3 and notification_type = 'shift_covered';
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'offer: original holder told the shift is covered');
  select count(*) into n from public.notifications where recipient_user_id = u_mgr and notification_type = 'shift_offer_accepted';
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'offer: sender told the offer was accepted');

  raise exception 'RESULT suite03 pass=% fail=% :: %',
    (select count(*) from unnest(r) x where x like 'PASS%'), (select count(*) from unnest(r) x where x like 'FAIL%'),
    array_to_string(r, '; ');
end $$;
