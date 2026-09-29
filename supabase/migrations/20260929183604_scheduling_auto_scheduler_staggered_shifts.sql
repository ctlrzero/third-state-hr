do $mig$
declare
  v_def text := pg_get_functiondef('public._auto_schedule(uuid, date, date, uuid[])'::regprocedure);
  v_old text := $o$        v_n := ceil(v_len / 540.0)::int;
        v_chunk := (floor(v_len::numeric / v_n / 15) * 15)::int;
        for i in 1 .. v_n loop
          v_s := w.start_time + make_interval(mins => (i - 1) * v_chunk);
          v_elapsed := case when i = v_n then v_len - (v_n - 1) * v_chunk else v_chunk end;
          v_e := v_s + make_interval(mins => v_elapsed);
          v_break := case when v_elapsed > 300 then 60 else 0 end;
          v_date := case when i > 1 and v_s < w.start_time then d + 1 else d end;$o$;
  v_new text := $n$        -- Long windows: overlapping full-length shifts (9h incl. 1h break) spread from open to close.
        v_n := ceil(v_len / 540.0)::int;
        for i in 1 .. v_n loop
          v_chunk := case when v_n = 1 or i = 1 then 0
                          when i = v_n then v_len - 540
                          else (floor(((v_len - 540)::numeric * (i - 1) / (v_n - 1)) / 15) * 15)::int end;
          v_elapsed := case when v_n = 1 then v_len else 540 end;
          v_s := w.start_time + make_interval(mins => v_chunk);
          v_e := v_s + make_interval(mins => v_elapsed);
          v_break := case when v_elapsed > 300 then 60 else 0 end;
          v_date := case when v_chunk > 0 and v_s < w.start_time then d + 1 else d end;$n$;
begin
  if strpos(v_def, v_old) = 0 then
    raise exception 'Expected slot-splitting block not found in _auto_schedule';
  end if;
  execute replace(v_def, v_old, v_new);
end
$mig$;;
