do $mig$
declare
  v_def text := pg_get_functiondef('public._auto_schedule(uuid, date, date, uuid[])'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def, 'public.locations l on l.id', 'public.locations loc on loc.id');
  v_new := replace(v_new, '''location'', l.name', '''location'', loc.name');
  v_new := replace(v_new, 'order by p.b_start, l.name, e.full_name', 'order by p.b_start, loc.name, e.full_name');
  v_new := replace(v_new, 'order by s.b_start, l.name)', 'order by s.b_start, loc.name)');
  if v_new = v_def or strpos(v_new, 'l.name') > 0 and strpos(v_new, ' l.name') > 0 and strpos(v_new, 'loc.name') = 0 then
    raise exception 'Alias replacement did not apply';
  end if;
  execute v_new;
end
$mig$;;
