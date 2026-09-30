-- Asking for one more personal detail while a personal-details request is already open adds it to that request
-- (and tells the employee) instead of being refused.
do $patch$
declare
  v_def text := pg_get_functiondef('public.request_selected_missing(uuid, text[], text, date)'::regprocedure);
  v_old text := $a$  if cardinality(v_fields) > 0 then
    begin
      perform public.create_employee_request(e.id, 'profile_info', null, v_fields, p_note, p_due_date);
      v_created := v_created || to_jsonb(array_to_string(v_field_labels, ', '));
    exception when others then
      v_skipped := v_skipped || jsonb_build_object('item', array_to_string(v_field_labels, ', '), 'reason', sqlerrm);
    end;
  end if;$a$;
begin
  if position(v_old in v_def) = 0 then
    raise exception 'request_selected_missing patch point not found';
  end if;
  execute replace(v_def, v_old, $a$  if cardinality(v_fields) > 0 then
    declare
      v_open public.employee_requests;
      v_new_fields text[];
    begin
      select * into v_open from public.employee_requests
      where employee_id = e.id and kind = 'profile_info' and status = 'open' limit 1;
      if v_open.id is not null then
        select array_agg(distinct f) into v_new_fields from unnest(coalesce(v_open.fields, '{}') || v_fields) f;
        if v_new_fields @> coalesce(v_open.fields, '{}') and cardinality(v_new_fields) = cardinality(coalesce(v_open.fields, '{}')) then
          v_skipped := v_skipped || jsonb_build_object('item', array_to_string(v_field_labels, ', '), 'reason', 'Already asked');
        else
          update public.employee_requests set fields = v_new_fields where id = v_open.id;
          perform public.create_notification(e.entity_id, null, e.id, 'employee_request', 'One more detail needed',
            'Your manager added more details to fill in: ' || array_to_string(v_field_labels, ', ') || '.',
            'employee_requests', v_open.id, 'high', 'employee_request_add:' || v_open.id || ':' || array_to_string(v_new_fields, ','));
          v_created := v_created || to_jsonb(array_to_string(v_field_labels, ', '));
        end if;
      else
        perform public.create_employee_request(e.id, 'profile_info', null, v_fields, p_note, p_due_date);
        v_created := v_created || to_jsonb(array_to_string(v_field_labels, ', '));
      end if;
    exception when others then
      v_skipped := v_skipped || jsonb_build_object('item', array_to_string(v_field_labels, ', '), 'reason', sqlerrm);
    end;
  end if;$a$);
end
$patch$;
