do $mig$
declare
  v_def text := pg_get_functiondef('public._auto_schedule(uuid, date, date, uuid[])'::regprocedure);
  v_new text := v_def;
  a text; b text;
begin
  a := 'break_minutes int, work_minutes int, b_start timestamptz, b_end timestamptz, filled boolean default false) on commit drop;';
  b := 'break_minutes int, work_minutes int, b_start timestamptz, b_end timestamptz, slot_rank int, filled boolean default false) on commit drop;';
  if strpos(v_new, a) = 0 then raise exception 'slots table text not found'; end if;
  v_new := replace(v_new, a, b);

  a := 'insert into pg_temp._as_slots (shift_date, location_id, position_id, start_time, end_time, break_minutes, work_minutes, b_start, b_end)';
  b := 'insert into pg_temp._as_slots (shift_date, location_id, position_id, start_time, end_time, break_minutes, work_minutes, b_start, b_end, slot_rank)';
  if strpos(v_new, a) = 0 then raise exception 'slot insert text not found'; end if;
  v_new := replace(v_new, a, b);

  a := 'values (v_date, l.id, w.position_id, v_s, v_e, v_break, v_elapsed - v_break, b_start, b_end);';
  b := 'values (v_date, l.id, w.position_id, v_s, v_e, v_break, v_elapsed - v_break, b_start, b_end, k);';
  if strpos(v_new, a) = 0 then raise exception 'slot values text not found'; end if;
  v_new := replace(v_new, a, b);

  a := 'for sl in select * from pg_temp._as_slots where not filled order by b_start, location_id, id loop';
  b := 'for sl in select * from pg_temp._as_slots where not filled order by shift_date, slot_rank, b_start, location_id, id loop';
  if strpos(v_new, a) = 0 then raise exception 'slot order text not found'; end if;
  v_new := replace(v_new, a, b);

  execute v_new;
end
$mig$;;
