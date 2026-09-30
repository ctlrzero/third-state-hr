-- Two smaller bugs found by the regression suite:
--  * request_shift_swap accepted a shift that isn't shared with staff yet (a draft) if you knew its id.
--    report_absence and send_shift_offer already refuse drafts; swaps now do too.
--  * New-leave and new-swap notices still went to revoked (inactive) branch managers. Only active ones now.
do $patch$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('public.request_shift_swap(uuid, text)'::regprocedure);
  if position($a$  if v_shift.id is null then raise exception 'Shift not found or not assigned to you'; end if;$a$ in v_def) = 0
     or position($a$select id from profiles where role = 'location_manager' and location_id = v_shift.location_id$a$ in v_def) = 0 then
    raise exception 'request_shift_swap patch points not found';
  end if;
  v_def := replace(v_def, $a$  select id, employee_id, shift_date, status, entity_id, location_id into v_shift$a$,
                          $a$  select id, employee_id, shift_date, status, entity_id, location_id, is_published into v_shift$a$);
  v_def := replace(v_def, $a$  if v_shift.id is null then raise exception 'Shift not found or not assigned to you'; end if;$a$,
                          $a$  if v_shift.id is null then raise exception 'Shift not found or not assigned to you'; end if;
  if not v_shift.is_published then
    raise exception using errcode = '22023', message = 'This shift isn’t shared with staff yet';
  end if;$a$);
  v_def := replace(v_def, $a$select id from profiles where role = 'location_manager' and location_id = v_shift.location_id$a$,
                          $a$select id from profiles where role = 'location_manager' and location_id = v_shift.location_id and is_active$a$);
  if position('is_published into v_shift' in v_def) = 0 then
    raise exception 'request_shift_swap select patch failed';
  end if;
  execute v_def;

  v_def := pg_get_functiondef('public.log_leave_request_changes()'::regprocedure);
  if position($a$select id from profiles where role = 'location_manager' and location_id = v_location_id$a$ in v_def) = 0 then
    raise exception 'log_leave_request_changes patch point not found';
  end if;
  execute replace(v_def, $a$select id from profiles where role = 'location_manager' and location_id = v_location_id$a$,
                         $a$select id from profiles where role = 'location_manager' and location_id = v_location_id and is_active$a$);
end
$patch$;
