-- P1-7 (part 2): what a shift supervisor may do. Own branch (profiles.location_id) only:
--   * Today board (no leave or document approvals counted for them)
--   * attendance exceptions and clock-time corrections (never their own record — existing guard)
--   * decide shift swaps (not ones they are part of) and find cover: reassign a published shift,
--     nothing else about it, and never to or from themselves
-- No pay, bank, documents of other people, employee edits or schedule building: every other role-gated
-- function lists roles explicitly, so the new role gets nothing there. A supervisor keeps all staff
-- self-service (own schedule, clock, leave, documents, payslips), which is keyed on their employee record.

-- Swaps waiting for a decision, shown on the Today board.
do $patch$
declare
  v_def text := pg_get_functiondef('public.get_branch_today(uuid)'::regprocedure);
  v_new text := v_def;
  v_parts text[][] := array[
    array[$a$    or (v_role = 'location_manager' and p_location_id = public.my_location())
  ) then$a$,
          $a$    or (v_role = 'location_manager' and p_location_id = public.my_location())
    or (v_role = 'shift_supervisor' and p_location_id = public.my_location())
  ) then$a$],
    array[$a$  v_pending_docs int;
$a$, $a$  v_pending_docs int;
  v_swaps jsonb;
$a$],
    array[$a$p.title as position, s.start_time, s.end_time, b.planned_start$a$,
          $a$p.title as position, s.shift_date, s.start_time, s.end_time, s.break_minutes, s.location_id, b.planned_start$a$],
    array[$a$'shift_id', s.id, 'position', p.title, 'start_time', s.start_time, 'end_time', s.end_time,$a$,
          $a$'shift_id', s.id, 'position', p.title, 'shift_date', s.shift_date, 'start_time', s.start_time, 'end_time', s.end_time,
           'break_minutes', s.break_minutes, 'location_id', s.location_id,$a$],
    array[$a$  return jsonb_build_object($a$,
          $a$  select coalesce(jsonb_agg(jsonb_build_object(
           'swap_id', ss.id, 'shift_id', s.id, 'shift_date', s.shift_date, 'start_time', s.start_time,
           'end_time', s.end_time, 'from_name', coalesce(r.preferred_name, r.full_name),
           'to_name', coalesce(c.preferred_name, c.full_name), 'notes', ss.notes)
         order by s.shift_date, s.start_time), '[]'::jsonb)
    into v_swaps
  from public.shift_swap_requests ss
  join public.shifts s on s.id = ss.shift_id
  left join public.employees r on r.id = ss.requested_by
  left join public.employees c on c.id = ss.claimed_by
  where s.location_id = p_location_id and ss.status = 'claimed' and ss.claimed_by is not null;

  -- Supervisors don't decide leave or review documents.
  if v_role = 'shift_supervisor' then
    v_pending_leave := 0;
    v_pending_docs := 0;
  end if;

  return jsonb_build_object($a$],
    array[$a$    'draft_shifts', v_drafts,$a$, $a$    'draft_shifts', v_drafts,
    'pending_swaps', v_swaps,$a$]
  ];
  i int;
begin
  for i in 1 .. array_length(v_parts, 1) loop
    if position(v_parts[i][1] in v_new) = 0 then
      raise exception 'get_branch_today patch point % not found', i;
    end if;
    v_new := replace(v_new, v_parts[i][1], v_parts[i][2]);
  end loop;
  execute v_new;
end
$patch$;

-- Branch gate for attendance exceptions, corrections, swap decisions and cover suggestions.
do $patch$
declare
  r record;
  v_def text;
  v_new text;
begin
  for r in
    select * from (values
      ('public.get_attendance_exceptions(uuid, date, date)',
       $a$    or (v_role = 'location_manager' and p_location_id = public.my_location())
$a$,
       $a$    or (v_role = 'location_manager' and p_location_id = public.my_location())
    or (v_role = 'shift_supervisor' and p_location_id = public.my_location())
$a$),
      ('public.correct_attendance_record(uuid, timestamp with time zone, timestamp with time zone, text)',
       $a$    or (v_role = 'location_manager' and v_row.location_id = public.my_location())
$a$,
       $a$    or (v_role = 'location_manager' and v_row.location_id = public.my_location())
    or (v_role = 'shift_supervisor' and v_row.location_id = public.my_location())
$a$),
      ('public.suggest_shift_cover(uuid)',
       $a$          or (public.my_role() = 'location_manager' and s.location_id = public.my_location())) then$a$,
       $a$          or (public.my_role() = 'location_manager' and s.location_id = public.my_location())
          or (public.my_role() = 'shift_supervisor' and s.location_id = public.my_location())) then$a$),
      ('public.approve_shift_swap(uuid, text)',
       $a$    or (my_role() = 'location_manager' and v_location_id = my_location())
  ) then
    raise exception 'Not authorized to decide this swap request';
  end if;
$a$,
       $a$    or (my_role() = 'location_manager' and v_location_id = my_location())
    or (my_role() = 'shift_supervisor' and v_location_id = my_location())
  ) then
    raise exception 'Not authorized to decide this swap request';
  end if;
  if my_role() = 'shift_supervisor' and my_employee_id() in (v_requested_by, v_claimed_by) then
    raise exception using errcode = '42501', message = 'You can''t decide a swap you are part of';
  end if;
$a$),
      ('public.adjust_published_shift(uuid, text, date, time without time zone, time without time zone, integer, uuid, uuid)',
       $a$    or (v_role = 'location_manager' and v.location_id = public.my_location())
  ) then
    raise exception using errcode = '42501', message = 'Not authorised to change this shift';
  end if;
$a$,
       $a$    or (v_role = 'location_manager' and v.location_id = public.my_location())
    or (v_role = 'shift_supervisor' and v.location_id = public.my_location())
  ) then
    raise exception using errcode = '42501', message = 'Not authorised to change this shift';
  end if;
  -- A supervisor finds cover: they may only change who works the shift.
  if v_role = 'shift_supervisor' then
    if coalesce(p_shift_date, v.shift_date) is distinct from v.shift_date
       or coalesce(p_start_time, v.start_time) is distinct from v.start_time
       or coalesce(p_end_time, v.end_time) is distinct from v.end_time
       or coalesce(p_break_minutes, v.break_minutes) is distinct from v.break_minutes
       or coalesce(p_location_id, v.location_id) is distinct from v.location_id
       or p_employee_id is null then
      raise exception using errcode = '42501', message = 'Supervisors can only reassign a shift to someone else';
    end if;
    if public.my_employee_id() in (p_employee_id, v.employee_id) then
      raise exception using errcode = '42501', message = 'You can''t reassign your own shift';
    end if;
  end if;
$a$)
    ) as t(sig, old_text, new_text)
  loop
    v_def := pg_get_functiondef(r.sig::regprocedure);
    if position(r.old_text in v_def) = 0 then
      raise exception '% patch point not found', r.sig;
    end if;
    v_new := replace(v_def, r.old_text, r.new_text);
    execute v_new;
  end loop;
end
$patch$;

-- Supervisors are told about "can't come in" reports at their branch too.
do $patch$
declare
  v_def text := pg_get_functiondef('public.report_absence(uuid, uuid, text)'::regprocedure);
  v_old text := $a$select p.id from public.profiles p where p.role = 'location_manager' and p.location_id = s.location_id and p.is_active$a$;
begin
  if position(v_old in v_def) = 0 then
    raise exception 'report_absence patch point not found';
  end if;
  execute replace(v_def, v_old,
    $a$select p.id from public.profiles p where p.role in ('location_manager', 'shift_supervisor') and p.location_id = s.location_id and p.is_active
        and p.id is distinct from auth.uid()$a$);
end
$patch$;

-- Access grants: a supervisor is an employee login tied to their home branch.
do $patch$
declare
  v_def text := pg_get_functiondef('public.admin_grant_access(text, public.user_role, uuid, uuid, uuid)'::regprocedure);
  v_new text := v_def;
  v_parts text[][] := array[
    array[$a$  if p_role = 'location_manager' and p_location_id is null then
    raise exception 'A location is required for a location manager' using errcode = '22023';$a$,
          $a$  if p_role in ('location_manager', 'shift_supervisor') and p_location_id is null then
    raise exception 'A branch is required for a location manager or shift supervisor' using errcode = '22023';$a$],
    array[$a$  if p_role = 'staff' and p_employee_id is null then
    raise exception 'Staff access must be linked to an employee record' using errcode = '22023';$a$,
          $a$  if p_role in ('staff', 'shift_supervisor') and p_employee_id is null then
    raise exception 'Staff and supervisor access must be linked to an employee record' using errcode = '22023';$a$],
    array[$a$    if p_role = 'staff' and p_location_id is not null and v_emp.home_location_id is distinct from p_location_id then$a$,
          $a$    if p_role in ('staff', 'shift_supervisor') and p_location_id is not null and v_emp.home_location_id is distinct from p_location_id then$a$]
  ];
  i int;
begin
  for i in 1 .. array_length(v_parts, 1) loop
    if position(v_parts[i][1] in v_new) = 0 then
      raise exception 'admin_grant_access patch point % not found', i;
    end if;
    v_new := replace(v_new, v_parts[i][1], v_parts[i][2]);
  end loop;
  execute v_new;
end
$patch$;

-- A supervisor's own document uploads are reviewed like a staff member's.
do $patch$
declare
  v_def text := pg_get_functiondef('public.can_review_document(uuid, uuid, public.document_type)'::regprocedure);
begin
  if position($a$if v_submitter_role = 'staff' then$a$ in v_def) = 0 then
    raise exception 'can_review_document patch point not found';
  end if;
  execute replace(v_def, $a$if v_submitter_role = 'staff' then$a$, $a$if v_submitter_role in ('staff', 'shift_supervisor') then$a$);
end
$patch$;

-- Transfers move a supervisor's login branch like a staff member's.
do $patch$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('public.enforce_profile_role_change_authority()'::regprocedure);
  if position($a$and old.role = 'staff' and new.role = old.role$a$ in v_def) = 0 then
    raise exception 'enforce_profile_role_change_authority patch point not found';
  end if;
  execute replace(v_def, $a$and old.role = 'staff' and new.role = old.role$a$,
                  $a$and old.role in ('staff', 'shift_supervisor') and new.role = old.role$a$);

  v_def := pg_get_functiondef('public._apply_employee_transfer(uuid)'::regprocedure);
  if position($a$where id = v_auth and role = 'staff' and$a$ in v_def) = 0 then
    raise exception '_apply_employee_transfer patch point not found';
  end if;
  execute replace(v_def, $a$where id = v_auth and role = 'staff' and$a$,
                  $a$where id = v_auth and role in ('staff', 'shift_supervisor') and$a$);
end
$patch$;

-- Own-document uploads (storage) for supervisors, same rule as staff.
drop policy doc_bucket_write on storage.objects;
create policy doc_bucket_write on storage.objects for insert to public with check (
  (bucket_id = 'employee-documents'::text) AND (
    ((my_role() = any (array['staff'::user_role, 'shift_supervisor'::user_role]))
       AND ((storage.foldername(name))[2] = (my_employee_id())::text) AND is_active_employee(my_employee_id()))
    OR (my_role() = 'owner'::user_role)
    OR ((my_role() = 'entity_admin'::user_role) AND ((storage.foldername(name))[1] = (my_entity())::text))
    OR ((my_role() = 'location_manager'::user_role) AND (EXISTS (
      SELECT 1 FROM employees e
      WHERE (((e.id)::text = (storage.foldername(objects.name))[2]) AND (e.home_location_id = my_location())))))));

drop policy doc_bucket_write_preboarding_self on storage.objects;
create policy doc_bucket_write_preboarding_self on storage.objects for insert to authenticated with check (
  (bucket_id = 'employee-documents'::text)
  AND ((SELECT my_role() AS my_role) = any (array['staff'::user_role, 'shift_supervisor'::user_role]))
  AND (EXISTS (
    SELECT 1 FROM employee_documents d
    WHERE ((d.storage_path = objects.name) AND (d.submitted_by = (SELECT auth.uid() AS uid))
           AND (NOT d.upload_confirmed) AND onboarding_is_preboarding_self(d.employee_id)))));
