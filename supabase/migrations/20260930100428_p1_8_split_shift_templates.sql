-- P1-8: split shifts from recurring templates.
-- generate_shifts_from_templates used to skip any day on which the person already had a shift, so a
-- second (split) template on the same weekday never produced a shift. It now skips only a shift that
-- would overlap one they already have — the same test validate_shift applies, including overnight
-- shifts from the day before or after — so a clash is skipped instead of failing the whole run.
-- Templates already allow several non-overlapping entries per person per weekday.
do $patch$
declare
  v_def text := pg_get_functiondef('public.generate_shifts_from_templates(uuid, date, date)'::regprocedure);
  v_old text := $a$    and not exists (
      select 1 from shifts s2 where s2.employee_id = t.employee_id and s2.shift_date = gs2.shift_date and s2.status <> 'cancelled'
    )$a$;
begin
  if position(v_old in v_def) = 0 then
    raise exception 'generate_shifts_from_templates patch point not found';
  end if;
  execute replace(v_def, v_old, $a$    and not exists (
      select 1
      from shifts s2
      cross join lateral _shift_planned_bounds(s2.shift_date, s2.start_time, s2.end_time) sb
      cross join lateral _shift_planned_bounds(gs2.shift_date, t.start_time, t.end_time) nb
      where s2.employee_id = t.employee_id
        and s2.status <> 'cancelled'
        and s2.shift_date between gs2.shift_date - 1 and gs2.shift_date + 1
        and tstzrange(sb.planned_start, sb.planned_end) && tstzrange(nb.planned_start, nb.planned_end)
    )$a$);
end
$patch$;
