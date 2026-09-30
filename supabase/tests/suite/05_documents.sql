-- Suite 05: document review rules (stage_document_upload -> confirm_document_upload -> approve/reject).
-- Business rule under test (do NOT change it): an Owner's own upload is approved immediately on confirm;
-- everyone else's upload stays pending_review and needs a second person to approve it.
-- A fake storage.objects row is inserted for each staged file so confirm_document_upload finds it;
-- like everything else it is rolled back by the final RAISE 'RESULT ...'.
do $$
declare
  v_owner uuid := '045a3ad2-0cbe-4c5e-85bf-df27dd29e14f';
  e1 uuid; la uuid;
  u_adm uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_st uuid := gen_random_uuid(); u_st2 uuid := gen_random_uuid();
  u_rev uuid := gen_random_uuid(); u_none uuid := gen_random_uuid();
  e_mgr uuid; e_st uuid; e_st2 uuid; e_rev uuid;
  d_own uuid; d_own_pp uuid; d_adm uuid; d_mgr uuid; d_self uuid; d_self_pp uuid; d_rej uuid; d_unconf uuid;
  j jsonb; r text[] := '{}'; st text; rb uuid; n int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.entities(name) values ('ZZ S05') returning id into e1;
  insert into public.locations(entity_id,name) values (e1,'ZZ A') returning id into la;
  insert into auth.users(id,email,aud,role) values
    (u_adm,'zz-s05-adm@example.invalid','authenticated','authenticated'),(u_mgr,'zz-s05-mgr@example.invalid','authenticated','authenticated'),
    (u_st,'zz-s05-st@example.invalid','authenticated','authenticated'),(u_st2,'zz-s05-st2@example.invalid','authenticated','authenticated'),
    (u_rev,'zz-s05-rev@example.invalid','authenticated','authenticated'),(u_none,'zz-s05-none@example.invalid','authenticated','authenticated');
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Mgr','active') returning id into e_mgr;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ St','active') returning id into e_st;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ St2','active') returning id into e_st2;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Rev','active') returning id into e_rev;
  perform public.admin_grant_access('zz-s05-adm@example.invalid','entity_admin',e1,null,null);
  perform public.admin_grant_access('zz-s05-mgr@example.invalid','location_manager',e1,la,e_mgr);
  perform public.admin_grant_access('zz-s05-st@example.invalid','staff',e1,la,e_st);
  perform public.admin_grant_access('zz-s05-st2@example.invalid','staff',e1,la,e_st2);
  perform public.admin_grant_access('zz-s05-rev@example.invalid','staff',e1,la,e_rev);
  perform public.admin_revoke_access(u_rev, null, 'ZZ suite: revoked staff');
  r := r || (case when not public.entity_admin_self_approval_enabled() then 'PASS ' else 'FAIL ' end || 'doc: precondition entity_admin_self_approval_enabled = false');

  perform set_config('role','authenticated',true);
  -- ===== 1. Owner uploads (non-restricted and restricted): approved immediately on confirm =====
  j := public.stage_document_upload(e_st, 'health_card', 'pdf'); d_own := (j->>'id')::uuid;
  perform set_config('role','postgres',true); insert into storage.objects(bucket_id,name) values ('employee-documents', j->>'storage_path'); perform set_config('role','authenticated',true);
  j := public.confirm_document_upload(d_own);
  select review_status, reviewed_by into st, rb from public.employee_documents where id = d_own;
  r := r || (case when st = 'approved' and rb = v_owner and j->>'review_status' = 'approved' then 'PASS ' else 'FAIL ' end || format('doc: owner own upload approved immediately (%s)', st));
  j := public.stage_document_upload(e_st, 'passport', 'pdf'); d_own_pp := (j->>'id')::uuid;
  perform set_config('role','postgres',true); insert into storage.objects(bucket_id,name) values ('employee-documents', j->>'storage_path'); perform set_config('role','authenticated',true);
  perform public.confirm_document_upload(d_own_pp);
  select review_status into st from public.employee_documents where id = d_own_pp;
  r := r || (case when st = 'approved' then 'PASS ' else 'FAIL ' end || format('doc: owner own restricted (passport) upload approved immediately (%s)', st));

  -- ===== 2. Entity admin upload: stays pending, cannot self-approve, owner approves =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  j := public.stage_document_upload(e_st2, 'health_card', 'pdf'); d_adm := (j->>'id')::uuid;
  perform set_config('role','postgres',true); insert into storage.objects(bucket_id,name) values ('employee-documents', j->>'storage_path'); perform set_config('role','authenticated',true);
  j := public.confirm_document_upload(d_adm);
  select review_status into st from public.employee_documents where id = d_adm;
  r := r || (case when st = 'pending_review' then 'PASS ' else 'FAIL ' end || format('doc: entity admin upload stays pending after confirm (%s)', st));
  begin perform public.approve_document(d_adm); r := r || 'FAIL doc: entity admin cannot approve own upload (allowed)'::text;
  exception when others then r := r || 'PASS doc: entity admin cannot approve own upload'::text; end;
  begin perform public.reject_document(d_adm, 'mine'); r := r || 'FAIL doc: uploader cannot reject own upload (allowed)'::text;
  exception when others then r := r || 'PASS doc: uploader cannot reject own upload'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin perform public.approve_document(d_adm); r := r || 'PASS doc: owner approves entity admin upload (second person)'::text;
  exception when others then r := r || ('FAIL doc: owner approves entity admin upload (' || sqlerrm || ')'); end;

  -- ===== 3. Manager upload: pending, cannot self-approve, entity admin approves; manager cannot upload restricted =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  j := public.stage_document_upload(e_st2, 'labor_card', 'jpg'); d_mgr := (j->>'id')::uuid;
  perform set_config('role','postgres',true); insert into storage.objects(bucket_id,name) values ('employee-documents', j->>'storage_path'); perform set_config('role','authenticated',true);
  perform public.confirm_document_upload(d_mgr);
  select review_status into st from public.employee_documents where id = d_mgr;
  r := r || (case when st = 'pending_review' then 'PASS ' else 'FAIL ' end || format('doc: manager upload stays pending after confirm (%s)', st));
  begin perform public.approve_document(d_mgr); r := r || 'FAIL doc: manager cannot approve own upload (allowed)'::text;
  exception when others then r := r || 'PASS doc: manager cannot approve own upload'::text; end;
  begin perform public.stage_document_upload(e_st2, 'passport', 'pdf'); r := r || 'FAIL doc: manager cannot upload restricted doc type (allowed)'::text;
  exception when others then r := r || 'PASS doc: manager cannot upload restricted doc type'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  begin perform public.approve_document(d_mgr); r := r || 'PASS doc: entity admin approves manager upload'::text;
  exception when others then r := r || ('FAIL doc: entity admin approves manager upload (' || sqlerrm || ')'); end;

  -- ===== 4. Staff self-upload: pending; staff cannot approve; manager approves non-restricted only =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  begin perform public.stage_document_upload(e_st2, 'health_card', 'pdf'); r := r || 'FAIL doc: staff cannot upload for a colleague (allowed)'::text;
  exception when others then r := r || 'PASS doc: staff cannot upload for a colleague'::text; end;
  j := public.stage_document_upload(e_st, 'visa', 'png'); d_self_pp := (j->>'id')::uuid;
  perform set_config('role','postgres',true); insert into storage.objects(bucket_id,name) values ('employee-documents', j->>'storage_path'); perform set_config('role','authenticated',true);
  perform public.confirm_document_upload(d_self_pp);
  j := public.stage_document_upload(e_st, 'labor_card', 'pdf'); d_self := (j->>'id')::uuid;
  r := r || (case when j->>'upload_method' = 'self' then 'PASS ' else 'FAIL ' end || 'doc: self upload recorded as upload_method=self');
  begin perform public.approve_document(d_self); r := r || 'FAIL doc: unconfirmed upload cannot be approved (allowed)'::text;
  exception when others then r := r || 'PASS doc: unconfirmed upload cannot be approved'::text; end;
  perform set_config('role','postgres',true); insert into storage.objects(bucket_id,name) values ('employee-documents', j->>'storage_path'); perform set_config('role','authenticated',true);
  perform public.confirm_document_upload(d_self);
  select review_status into st from public.employee_documents where id = d_self;
  r := r || (case when st = 'pending_review' then 'PASS ' else 'FAIL ' end || format('doc: staff upload stays pending after confirm (%s)', st));
  begin perform public.approve_document(d_self); r := r || 'FAIL doc: staff cannot approve own upload (allowed)'::text;
  exception when others then r := r || 'PASS doc: staff cannot approve own upload'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_st2, 'role', 'authenticated')::text, true);
  begin perform public.approve_document(d_self); r := r || 'FAIL doc: colleague (staff) cannot approve (allowed)'::text;
  exception when others then r := r || 'PASS doc: colleague (staff) cannot approve'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin perform public.approve_document(d_self); r := r || 'PASS doc: manager approves staff non-restricted upload'::text;
  exception when others then r := r || ('FAIL doc: manager approves staff non-restricted upload (' || sqlerrm || ')'); end;
  begin perform public.approve_document(d_self_pp); r := r || 'FAIL doc: manager cannot approve restricted (visa) upload (allowed)'::text;
  exception when others then r := r || 'PASS doc: manager cannot approve restricted (visa) upload'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  begin perform public.approve_document(d_self_pp); r := r || 'PASS doc: entity admin approves restricted staff upload'::text;
  exception when others then r := r || ('FAIL doc: entity admin approves restricted staff upload (' || sqlerrm || ')'); end;
  begin perform public.approve_document(d_self_pp); r := r || 'FAIL doc: already-approved document cannot be approved again (allowed)'::text;
  exception when others then r := r || 'PASS doc: already-approved document cannot be approved again'::text; end;

  -- ===== 5. Reject rules =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_st2, 'role', 'authenticated')::text, true);
  j := public.stage_document_upload(e_st2, 'other', 'pdf'); d_rej := (j->>'id')::uuid;
  perform set_config('role','postgres',true); insert into storage.objects(bucket_id,name) values ('employee-documents', j->>'storage_path'); perform set_config('role','authenticated',true);
  perform public.confirm_document_upload(d_rej);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin perform public.reject_document(d_rej, '  '); r := r || 'FAIL doc: reject needs a reason (allowed)'::text;
  exception when others then r := r || 'PASS doc: reject needs a reason'::text; end;
  begin perform public.reject_document(d_rej, 'ZZ blurry'); r := r || 'PASS doc: manager rejects with reason'::text;
  exception when others then r := r || ('FAIL doc: manager rejects with reason (' || sqlerrm || ')'); end;
  perform set_config('role','postgres',true);
  select review_status into st from public.employee_documents where id = d_rej;
  select count(*) into n from public.notifications where target_id = d_rej and notification_type = 'document_rejected' and employee_id = e_st2;
  r := r || (case when st = 'rejected' and n = 1 then 'PASS ' else 'FAIL ' end || format('doc: rejected status stored and employee notified (%s, %s)', st, n));
  select count(*) into n from public.audit_log where record_id in (d_own, d_adm, d_mgr, d_self) and action = 'document_approved';
  r := r || (case when n = 4 then 'PASS ' else 'FAIL ' end || format('doc: approvals audited (%s/4)', n));

  -- ===== 6. Direct-table shortcuts are blocked =====
  begin
    insert into public.employee_documents(employee_id,doc_type,storage_path,review_status,submitted_by,submitted_at,uploaded_by)
    values (e_st,'other','zz/x','approved',v_owner,now(),v_owner);
    r := r || 'FAIL doc: approved insert without reviewed_by refused (allowed)'::text;
  exception when others then r := r || 'PASS doc: approved insert without reviewed_by refused'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  begin
    insert into public.employee_documents(employee_id,doc_type,storage_path,review_status,submitted_by,submitted_at,uploaded_by,reviewed_by,reviewed_at)
    values (e_st,'other','zz/x','approved',u_adm,now(),u_adm,u_adm,now());
    r := r || 'FAIL doc: entity admin cannot insert own upload as approved (trigger) (allowed)'::text;
  exception when others then r := r || 'PASS doc: entity admin cannot insert own upload as approved (trigger)'::text; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  perform set_config('role','authenticated',true);
  begin
    insert into public.employee_documents(employee_id,doc_type,storage_path,review_status,submitted_by,submitted_at,uploaded_by,reviewed_by,reviewed_at,upload_confirmed)
    values (e_st,'other','zz/y','approved',u_st,now(),u_st,u_st,now(),true);
    r := r || 'FAIL doc: staff cannot insert an approved document via API (allowed)'::text;
  exception when others then r := r || 'PASS doc: staff cannot insert an approved document via API'::text; end;
  begin update public.employee_documents set review_status = 'approved' where id = d_rej; get diagnostics n = row_count;
    r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'doc: staff cannot flip review_status via API');
  exception when others then r := r || 'PASS doc: staff cannot flip review_status via API'::text; end;

  -- ===== 7. Revoked login / login without profile cannot stage uploads (success rolled back) =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_rev, 'role', 'authenticated')::text, true);
  begin perform public.stage_document_upload(e_st, 'other', 'pdf'); raise exception 'zz_allowed';
  exception when others then r := r || (case when sqlerrm = 'zz_allowed' then 'FAIL ' else 'PASS ' end || 'doc: revoked user cannot stage an upload for an employee'); end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_none, 'role', 'authenticated')::text, true);
  begin perform public.stage_document_upload(e_st, 'other', 'pdf'); raise exception 'zz_allowed';
  exception when others then r := r || (case when sqlerrm = 'zz_allowed' then 'FAIL ' else 'PASS ' end || 'doc: login without profile cannot stage an upload for an employee'); end;
  begin perform public.approve_document(d_rej); r := r || 'FAIL doc: login without profile cannot approve (allowed)'::text;
  exception when others then r := r || 'PASS doc: login without profile cannot approve'::text; end;
  perform set_config('role','postgres',true);

  raise exception 'RESULT suite05 pass=% fail=% :: %',
    (select count(*) from unnest(r) x where x like 'PASS%'), (select count(*) from unnest(r) x where x like 'FAIL%'),
    array_to_string(r, '; ');
end $$;
