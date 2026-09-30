-- "Ask an employee for something" (employee_requests) test. Self-contained: builds a throwaway company with
-- two branches, a Branch Manager, a Shift Supervisor and employees, runs every check as the right person and
-- ends with RAISE, so nothing is kept. Run as postgres (SQL editor / MCP execute_sql).
-- Expected output (one line):
--   RESULT lm-own:ok lm-other-branch:refused lm-restricted:refused sup:refused staff:refused dup:refused
--   notified=1 mine=1 other-staff=0 staff-list:refused lm-list=1 doc-close:done sender-notified=1
--   pay-no-request:refused pay:done profile-part:open profile-full:done cancel-staff:refused cancel-sup:refused
--   cancel-lm:cancelled cancel-again:refused remind1=1 remind2=0 overdue-notices=1 last-reminded=today
-- Needs an active owner profile; set v_owner below.
do $$
declare v_owner uuid := '045a3ad2-0cbe-4c5e-85bf-df27dd29e14f';
  v_ent uuid; a uuid; b uuid; e_lm uuid; e_sup uuid; e_s1 uuid; e_s2 uuid; e_b uuid;
  u_lm uuid := gen_random_uuid(); u_sup uuid := gen_random_uuid(); u_s1 uuid := gen_random_uuid(); u_s2 uuid := gen_random_uuid();
  t date := (now() at time zone 'Asia/Dubai')::date; r jsonb; out text := ''; n int; st text;
  req_doc uuid; req_pay uuid; req_prof uuid; req_cancel uuid; req_due uuid; d jsonb;
begin
  -- ---- setup (as owner, because a trigger protects profiles) ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.entities(name) values ('ZZ EmpReq') returning id into v_ent;
  insert into public.locations(entity_id,name) values (v_ent,'A') returning id into a;
  insert into public.locations(entity_id,name) values (v_ent,'B') returning id into b;
  insert into auth.users(id,email,aud,role) values
    (u_lm,'zz-er-lm@example.invalid','authenticated','authenticated'), (u_sup,'zz-er-sup@example.invalid','authenticated','authenticated'),
    (u_s1,'zz-er-s1@example.invalid','authenticated','authenticated'), (u_s2,'zz-er-s2@example.invalid','authenticated','authenticated');
  insert into public.employees(entity_id,home_location_id,full_name,employment_status,auth_user_id) values (v_ent,a,'ZZ Manager','active',u_lm) returning id into e_lm;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status,auth_user_id) values (v_ent,a,'ZZ Sup','active',u_sup) returning id into e_sup;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status,auth_user_id) values (v_ent,a,'ZZ Staff One','active',u_s1) returning id into e_s1;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status,auth_user_id,phone,dob) values (v_ent,a,'ZZ Staff Two','active',u_s2,null,null) returning id into e_s2;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (v_ent,b,'ZZ At B','active') returning id into e_b;
  perform public.admin_grant_access('zz-er-lm@example.invalid', 'location_manager', v_ent, a, e_lm);
  perform public.admin_grant_access('zz-er-sup@example.invalid', 'shift_supervisor', v_ent, a, e_sup);
  perform public.admin_grant_access('zz-er-s1@example.invalid', 'staff', v_ent, a, e_s1);
  perform public.admin_grant_access('zz-er-s2@example.invalid', 'staff', v_ent, a, e_s2);

  -- ---- Branch Manager: own branch only, no restricted documents ----
  perform set_config('request.jwt.claims', json_build_object('sub', u_lm, 'role', 'authenticated')::text, true);
  r := public.create_employee_request(e_s1, 'document', 'health_card', null, 'Your old one expired', t + 3);
  req_doc := (r->>'id')::uuid; out := out || 'lm-own:' || case when r->>'ok' = 'true' then 'ok' else 'FAIL' end || ' ';
  begin perform public.create_employee_request(e_b, 'payment_details'); out := out || 'lm-other-branch:ALLOWED ';
  exception when others then out := out || 'lm-other-branch:refused '; end;
  begin perform public.create_employee_request(e_s1, 'document', 'passport'); out := out || 'lm-restricted:ALLOWED ';
  exception when others then out := out || 'lm-restricted:refused '; end;

  -- ---- Shift Supervisor / Employee can't send ----
  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  begin perform public.create_employee_request(e_s1, 'payment_details'); out := out || 'sup:ALLOWED ';
  exception when others then out := out || 'sup:refused '; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_s2, 'role', 'authenticated')::text, true);
  begin perform public.create_employee_request(e_s1, 'payment_details'); out := out || 'staff:ALLOWED ';
  exception when others then out := out || 'staff:refused '; end;

  -- duplicate open request
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin perform public.create_employee_request(e_s1, 'document', 'health_card'); out := out || 'dup:ALLOWED ';
  exception when others then out := out || 'dup:refused '; end;
  select count(*) into n from public.notifications where employee_id = e_s1 and notification_type = 'employee_request' and target_id = req_doc;
  out := out || 'notified=' || n || ' ';

  -- ---- employee sees own open requests only ----
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  select count(*) into n from public.get_my_employee_requests(); out := out || 'mine=' || n || ' ';
  perform set_config('request.jwt.claims', json_build_object('sub', u_s2, 'role', 'authenticated')::text, true);
  select count(*) into n from public.get_my_employee_requests(); out := out || 'other-staff=' || n || ' ';
  begin perform public.get_employee_requests(e_s1); out := out || 'staff-list:ALLOWED ';
  exception when others then out := out || 'staff-list:refused '; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_lm, 'role', 'authenticated')::text, true);
  select count(*) into n from public.get_employee_requests(e_s1); out := out || 'lm-list=' || n || ' ';

  -- ---- auto-close: document uploaded (staged by the employee, then confirmed) ----
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  d := public.stage_document_upload(e_s1, 'health_card', 'pdf', t + 365, null, null);
  update public.employee_documents set upload_confirmed = true, upload_confirmed_at = now() where id = (d->>'id')::uuid;
  select status into st from public.employee_requests where id = req_doc; out := out || 'doc-close:' || st || ' ';
  select count(*) into n from public.notifications where recipient_user_id = u_lm and notification_type = 'employee_request_done';
  out := out || 'sender-notified=' || n || ' ';

  -- ---- auto-close: payment details ----
  begin perform public.submit_requested_payment_details('bank_transfer', 'ZZ Bank', 'ZZ Staff One', 'AE070331234567890123456');
    out := out || 'pay-no-request:ALLOWED ';
  exception when others then out := out || 'pay-no-request:refused '; end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  req_pay := (public.create_employee_request(e_s1, 'payment_details')->>'id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  perform public.submit_requested_payment_details('bank_transfer', 'ZZ Bank', 'ZZ Staff One', 'AE07 0331 2345 6789 0123 456');
  select status into st from public.employee_requests where id = req_pay; out := out || 'pay:' || st || ' ';

  -- ---- auto-close: profile details (only when every asked field is filled) ----
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  req_prof := (public.create_employee_request(e_s2, 'profile_info', null, array['phone', 'dob'])->>'id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', u_s2, 'role', 'authenticated')::text, true);
  perform public.fill_my_requested_profile_info('{"phone":"+971 50 123 4567"}');
  select status into st from public.employee_requests where id = req_prof; out := out || 'profile-part:' || st || ' ';
  perform public.fill_my_requested_profile_info('{"dob":"1995-04-02"}');
  select status into st from public.employee_requests where id = req_prof; out := out || 'profile-full:' || st || ' ';

  -- ---- cancel: sender only ----
  perform set_config('request.jwt.claims', json_build_object('sub', u_lm, 'role', 'authenticated')::text, true);
  req_cancel := (public.create_employee_request(e_s2, 'payment_details')->>'id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', u_s2, 'role', 'authenticated')::text, true);
  begin perform public.cancel_employee_request(req_cancel); out := out || 'cancel-staff:ALLOWED ';
  exception when others then out := out || 'cancel-staff:refused '; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  begin perform public.cancel_employee_request(req_cancel); out := out || 'cancel-sup:ALLOWED ';
  exception when others then out := out || 'cancel-sup:refused '; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_lm, 'role', 'authenticated')::text, true);
  perform public.cancel_employee_request(req_cancel);
  select status into st from public.employee_requests where id = req_cancel; out := out || 'cancel-lm:' || st || ' ';
  begin perform public.cancel_employee_request(req_cancel); out := out || 'cancel-again:ALLOWED ';
  exception when others then out := out || 'cancel-again:refused '; end;

  -- ---- overdue reminder: once per day ----
  req_due := (public.create_employee_request(e_s2, 'document', 'health_card', null, null, t)->>'id')::uuid;
  perform set_config('request.jwt.claims', '', true);
  update public.employee_requests set due_date = t - 2 where id = req_due;
  perform public._emp_req_reminders(t);
  select count(*) into n from public.notifications where employee_id = e_s2 and notification_type = 'employee_request_overdue';
  out := out || 'remind1=' || n || ' ';
  perform public._emp_req_reminders(t);
  select count(*) - n into n from public.notifications where employee_id = e_s2 and notification_type = 'employee_request_overdue';
  out := out || 'remind2=' || n || ' ';
  select count(*) into n from public.notifications where employee_id = e_s2 and notification_type = 'employee_request_overdue';
  out := out || 'overdue-notices=' || n || ' ';
  select case when last_reminded_on = t then 'today' else coalesce(last_reminded_on::text, 'null') end into st
    from public.employee_requests where id = req_due;
  out := out || 'last-reminded=' || st;

  raise exception 'RESULT %', out;
end $$;
