-- Label fix: "Emirates ID" (not "Emirates Id") in request_all_missing results.
do $patch$
declare v_def text := pg_get_functiondef('public.request_all_missing(uuid, text, date)'::regprocedure);
begin
  if position($a$initcap(replace(v_doc, '_', ' '))$a$ in v_def) = 0 then raise exception 'patch point not found'; end if;
  execute replace(v_def, $a$initcap(replace(v_doc, '_', ' '))$a$,
    $a$(case v_doc when 'emirates_id' then 'Emirates ID' else initcap(replace(v_doc, '_', ' ')) end)$a$);
end
$patch$;
