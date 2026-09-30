-- Every change of an existing home branch goes through transfer_employee (review list, audit, notices).
-- update_employee_details can still set a branch for someone who has none.
do $patch$
declare
  v_def text := pg_get_functiondef('public.update_employee_details(uuid, jsonb)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
    $a$  if v_new.probation_end_date is not null and v_new.join_date is not null$a$,
    $a$  if v_new.home_location_id is distinct from v_old.home_location_id and v_old.home_location_id is not null then
    raise exception 'To change the home branch, use Transfer on the employee profile' using errcode = '22023';
  end if;
  if v_new.probation_end_date is not null and v_new.join_date is not null$a$);
  if v_new = v_def then
    raise exception 'update_employee_details patch point not found';
  end if;
  execute v_new;
end
$patch$;
