-- P1-4: get_branch_today marks shifts whose employee reported "can't come in" (with a pending or
-- approved leave request) as 'absent_reported', and returns the linked leave request and note.
do $patch$
declare
  v_def text := pg_get_functiondef('public.get_branch_today(uuid)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
    $a$           a.id as attendance_id, a.clock_in_at, a.clock_out_at,
$a$,
    $a$           a.id as attendance_id, a.clock_in_at, a.clock_out_at,
           ab.leave_request_id as absence_leave_request_id, ab.leave_status as absence_leave_status, ab.note as absence_note,
$a$);
  v_new := replace(v_new,
    $a$           case when a.id is not null and a.clock_out_at is not null then 'done'$a$,
    $a$           case when a.id is null and ab.leave_request_id is not null then 'absent_reported'
                when a.id is not null and a.clock_out_at is not null then 'done'$a$);
  v_new := replace(v_new,
    $a$    ) a on true
    where s.location_id = p_location_id and s.shift_date = v_today$a$,
    $a$    ) a on true
    left join lateral (
      select (sa.new_values->>'leave_request_id')::uuid as leave_request_id, lr.status as leave_status, sa.reason as note
      from public.shift_adjustments sa
      join public.leave_requests lr on lr.id = (sa.new_values->>'leave_request_id')::uuid
      where sa.shift_id = s.id and sa.change_type = 'absence_reported' and sa.employee_id = s.employee_id
        and lr.status in ('pending', 'approved')
      order by sa.changed_at desc limit 1
    ) ab on true
    where s.location_id = p_location_id and s.shift_date = v_today$a$);
  if v_new = v_def or position('absent_reported' in v_new) = 0 or position(') ab on true' in v_new) = 0
     or position('absence_leave_request_id' in v_new) = 0 then
    raise exception 'get_branch_today patch points not found';
  end if;
  execute v_new;
end
$patch$;
