-- UX review: the Today board shows when a cover offer is already out ("Offer sent · waiting"),
-- so a manager doesn't offer or assign the same shift twice. Adds offer_pending to people[] and open_gaps[].
do $patch$
declare
  v_def text := pg_get_functiondef('public.get_branch_today(uuid)'::regprocedure);
  v_new text := v_def;
  v_parts text[][] := array[
    array[$a$           ab.leave_request_id as absence_leave_request_id,$a$,
          $a$           exists (select 1 from public.shift_offers so where so.shift_id = s.id and so.status = 'pending') as offer_pending,
           ab.leave_request_id as absence_leave_request_id,$a$],
    array[$a$           'break_minutes', s.break_minutes, 'location_id', s.location_id,$a$,
          $a$           'break_minutes', s.break_minutes, 'location_id', s.location_id,
           'offer_pending', exists (select 1 from public.shift_offers so where so.shift_id = s.id and so.status = 'pending'),$a$]
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
