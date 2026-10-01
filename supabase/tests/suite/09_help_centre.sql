-- Suite 09: Help Centre RPCs. Self-contained: throwaway entity, logins and articles (slugs start zz-), all rolled back by the final RAISE 'RESULT ...'.
-- Covers: audience filtering (staff never get manager/admin-only articles), drafts invisible to non-admins, only Owner / Company Admin
-- can save, publish, restore, review; publish creates a version; restore puts an old version back into a draft; no-role logins are refused;
-- anon cannot call the RPCs; direct table access is blocked.
do $$
declare
  v_owner uuid := '045a3ad2-0cbe-4c5e-85bf-df27dd29e14f';
  e1 uuid; la uuid;
  u_adm uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_st uuid := gen_random_uuid();
  u_rev uuid := gen_random_uuid(); u_none uuid := gen_random_uuid();
  em_st uuid; em_rev uuid;
  j jsonb; n int; s text; ok boolean;
  r text[] := '{}';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  insert into public.entities(name) values ('ZZ S09') returning id into e1;
  insert into public.locations(entity_id,name) values (e1,'ZZ A') returning id into la;
  insert into auth.users(id,email,aud,role) values
    (u_adm,'zz-s09-adm@example.invalid','authenticated','authenticated'),(u_mgr,'zz-s09-mgr@example.invalid','authenticated','authenticated'),
    (u_st,'zz-s09-st@example.invalid','authenticated','authenticated'),(u_rev,'zz-s09-rev@example.invalid','authenticated','authenticated'),
    (u_none,'zz-s09-none@example.invalid','authenticated','authenticated');
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ St','active') returning id into em_st;
  insert into public.employees(entity_id,home_location_id,full_name,employment_status) values (e1,la,'ZZ Rev','active') returning id into em_rev;
  perform public.admin_grant_access('zz-s09-adm@example.invalid','entity_admin',e1,null,null);
  perform public.admin_grant_access('zz-s09-mgr@example.invalid','location_manager',e1,la,null);
  perform public.admin_grant_access('zz-s09-st@example.invalid','staff',e1,la,em_st);
  perform public.admin_grant_access('zz-s09-rev@example.invalid','staff',e1,la,em_rev);
  update public.profiles set is_active = false where id = u_rev;

  r := r || (case when has_function_privilege('authenticated','public.help_list_articles()','execute')
                   and has_function_privilege('authenticated','public.help_search(text)','execute')
                   and has_function_privilege('authenticated','public.help_admin_publish(text,text,date)','execute')
                   and has_function_privilege('authenticated','public._help_is_admin()','execute')
                   and not has_function_privilege('anon','public.help_list_articles()','execute')
                   and not has_function_privilege('anon','public.help_admin_list()','execute')
                  then 'PASS ' else 'FAIL ' end || 'help: grants (authenticated yes, anon no)')::text;

  -- Company Admin writes two articles: one for everybody, one for admins only.
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  perform public.help_admin_save_draft('zz-open-guide','ZZ Open guide','employee','{staff,shift_supervisor,location_manager}','How to zebra','Step one: feed the zebra.','{}',null);
  perform public.help_admin_save_draft('zz-admin-guide','ZZ Admin guide','admin','{entity_admin,owner}','Admin only','Secret platypus procedure.','{}',null);
  select count(*) into n from public.help_admin_list() where slug like 'zz-%';
  r := r || (case when n = 2 then 'PASS ' else 'FAIL ' end || 'help: admin sees both drafts in the admin list')::text;
  j := public.help_admin_publish('zz-open-guide','First version');
  r := r || (case when (j->>'version')::int = 1 then 'PASS ' else 'FAIL ' end || 'help: publish creates version 1')::text;
  select count(*) into n from public.help_admin_versions('zz-open-guide');
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'help: version history has the new version')::text;
  j := public.help_admin_get('zz-open-guide');
  r := r || (case when (j->>'last_reviewed')::date = current_date and j->>'status' = 'published' then 'PASS ' else 'FAIL ' end || 'help: publish sets last_reviewed to today')::text;
  -- Publishing the admin guide, then a second edit on the open guide stays a draft until published.
  perform public.help_admin_publish('zz-admin-guide','Admin v1');
  perform public.help_admin_save_draft('zz-open-guide','ZZ Open guide','employee','{staff,shift_supervisor,location_manager}','How to zebra','Step one: feed the giraffe.','{}',null);
  select count(*) into n from public.help_get_article('zz-open-guide') where body_md like '%zebra%';
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'help: unpublished edits do not change the live article')::text;
  j := public.help_admin_publish('zz-open-guide','Second version');
  r := r || (case when (j->>'version')::int = 2 then 'PASS ' else 'FAIL ' end || 'help: second publish is version 2')::text;
  -- A brand new, never published article.
  perform public.help_admin_save_draft('zz-draft-only','ZZ Draft only','employee','{staff}','Never published','Hidden narwhal text.','{}',null);
  -- Restore version 1 into a draft; live stays at version 2.
  j := public.help_admin_restore_version('zz-open-guide', 1);
  j := public.help_admin_get('zz-open-guide');
  r := r || (case when j->'draft'->>'body_md' like '%zebra%' and j->'live'->>'body_md' like '%giraffe%' then 'PASS ' else 'FAIL ' end
             || 'help: restore puts the old version into a draft and leaves the live article alone')::text;
  perform public.help_admin_mark_reviewed('zz-open-guide');
  r := r || (case when (public.help_admin_get('zz-open-guide')->>'last_reviewed')::date = current_date then 'PASS ' else 'FAIL ' end || 'help: mark reviewed')::text;
  select count(*) into n from public.help_list_articles() where slug like 'zz-%';
  r := r || (case when n = 2 then 'PASS ' else 'FAIL ' end || 'help: admin reader list has both published, not the draft-only one')::text;

  -- Staff: only the open guide; no admin guide, no draft, no search leak.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_st, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  select string_agg(slug, ',') into s from public.help_list_articles() where slug like 'zz-%';
  r := r || (case when s = 'zz-open-guide' then 'PASS ' else 'FAIL ' end || format('help: staff list shows only the open guide (%s)', s))::text;
  select count(*) into n from public.help_get_article('zz-admin-guide');
  r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'help: staff cannot read an admin-only article')::text;
  select count(*) into n from public.help_get_article('zz-draft-only');
  r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'help: staff cannot read a draft')::text;
  select count(*) into n from public.help_search('platypus');
  r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'help: search does not leak admin-only text to staff')::text;
  select count(*) into n from public.help_search('narwhal');
  r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'help: search does not leak draft text')::text;
  select count(*) into n from public.help_search('giraffe');
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'help: search finds the published open guide (full text)')::text;
  select count(*) into n from public.help_search('gira');
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'help: search finds partial words (ILIKE fallback)')::text;
  ok := false; begin perform public.help_admin_save_draft('zz-staff-try','T','employee','{staff}','','x','{}',null); exception when others then ok := sqlerrm like 'Only an Owner%'; end;
  r := r || (case when ok then 'PASS ' else 'FAIL ' end || 'help: staff cannot save a draft')::text;
  ok := false; begin perform public.help_admin_publish('zz-open-guide','hack'); exception when others then ok := sqlerrm like 'Only an Owner%'; end;
  r := r || (case when ok then 'PASS ' else 'FAIL ' end || 'help: staff cannot publish')::text;
  ok := false; begin perform * from public.help_admin_list(); exception when others then ok := sqlerrm like 'Only an Owner%'; end;
  r := r || (case when ok then 'PASS ' else 'FAIL ' end || 'help: staff cannot open the admin list')::text;
  ok := false; begin perform public.help_admin_get('zz-draft-only'); exception when others then ok := sqlerrm like 'Only an Owner%'; end;
  r := r || (case when ok then 'PASS ' else 'FAIL ' end || 'help: staff cannot read a draft through the admin RPC')::text;
  ok := false; begin perform public.help_admin_restore_version('zz-open-guide',1); exception when others then ok := sqlerrm like 'Only an Owner%'; end;
  r := r || (case when ok then 'PASS ' else 'FAIL ' end || 'help: staff cannot restore')::text;
  ok := false; begin perform * from public.help_articles; exception when others then ok := true; end;
  r := r || (case when ok then 'PASS ' else 'FAIL ' end || 'help: staff cannot read the table directly')::text;

  -- Branch manager: sees the open guide, cannot manage.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  select count(*) into n from public.help_list_articles() where slug = 'zz-open-guide';
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'help: branch manager reads the open guide')::text;
  select count(*) into n from public.help_list_articles() where slug = 'zz-admin-guide';
  r := r || (case when n = 0 then 'PASS ' else 'FAIL ' end || 'help: branch manager cannot see admin-only article')::text;
  ok := false; begin perform public.help_admin_publish('zz-open-guide','hack'); exception when others then ok := sqlerrm like 'Only an Owner%'; end;
  r := r || (case when ok then 'PASS ' else 'FAIL ' end || 'help: branch manager cannot publish')::text;

  -- Owner sees admin-only articles too.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  select count(*) into n from public.help_list_articles() where slug = 'zz-admin-guide';
  r := r || (case when n = 1 then 'PASS ' else 'FAIL ' end || 'help: owner sees admin-only article')::text;

  -- Revoked and no-profile logins are refused everywhere.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_rev, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  ok := false; begin perform * from public.help_list_articles(); exception when others then ok := sqlstate = '42501'; end;
  r := r || (case when ok then 'PASS ' else 'FAIL ' end || 'help: revoked login refused (list)')::text;
  ok := false; begin perform public.help_admin_publish('zz-open-guide','x'); exception when others then ok := sqlstate = '42501'; end;
  r := r || (case when ok then 'PASS ' else 'FAIL ' end || 'help: revoked login refused (publish)')::text;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_none, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  ok := false; begin perform * from public.help_search('zebra'); exception when others then ok := sqlstate = '42501'; end;
  r := r || (case when ok then 'PASS ' else 'FAIL ' end || 'help: login without a profile refused (search)')::text;
  ok := false; begin perform public.help_admin_save_draft('zz-none','T','employee','{staff}','','x','{}',null); exception when others then ok := sqlstate = '42501'; end;
  r := r || (case when ok then 'PASS ' else 'FAIL ' end || 'help: login without a profile refused (save draft)')::text;

  -- Signed out.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'anon', true);
  ok := false; begin perform * from public.help_list_articles(); exception when others then ok := true; end;
  r := r || (case when ok then 'PASS ' else 'FAIL ' end || 'help: signed-out user cannot call the RPCs')::text;
  perform set_config('role', 'postgres', true);

  raise exception 'RESULT suite09 pass=% fail=% :: %',
    (select count(*) from unnest(r) x where x like 'PASS%'), (select count(*) from unnest(r) x where x like 'FAIL%'),
    array_to_string(r, '; ');
end $$;
