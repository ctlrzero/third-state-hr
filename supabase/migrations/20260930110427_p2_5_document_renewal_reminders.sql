-- P2-5: Renewal coordinator — document expiry reminders at 60, 30 and 7 days, on the day, and weekly
-- for 8 weeks after expiry. Runs as a 4th step of the daily HR reminders job (06:00 Dubai).
--   * The employee gets a notice with the step to take ("Upload new copy" in Documents).
--   * HR gets one digest per person per day: owners and company admins (all documents), and the branch
--     manager of the employee's home branch (not restricted document types).
--   * A document whose renewal is already uploaded and waiting for review is skipped for the employee;
--     reviewers see it in the review queue as today.
-- English only for now (the owner skipped P1-9). No AI: the wording is fixed and factual.

create or replace function public._doc_renewal_reminders(p_today date)
returns int
language plpgsql
security definer
set search_path to ''
as $function$
declare
  d record;
  v_days int;
  v_stage text;
  v_label text;
  v_when text;
  v_title text;
  v_n int := 0;
  r record;
begin
  create temp table if not exists _renewal_due (
    entity_id uuid, location_id uuid, employee_name text, label text, days int, restricted boolean
  ) on commit drop;
  truncate pg_temp._renewal_due;

  for d in
    select ed.id, ed.employee_id, ed.doc_type, ed.expiry_date, e.entity_id, e.home_location_id,
           coalesce(e.preferred_name, e.full_name) as employee_name
    from public.employee_documents ed
    join public.employees e on e.id = ed.employee_id
    where ed.is_current and ed.archived_at is null and ed.expiry_date is not null
      and coalesce(ed.review_status, 'approved') not in ('rejected', 'archived', 'superseded')
      and e.employment_status in ('active', 'pre_boarding')
      and ed.expiry_date between p_today - 56 and p_today + 60
      and not exists (select 1 from public.employee_documents nx
                      where nx.supersedes_document_id = ed.id and nx.archived_at is null
                        and nx.review_status = 'pending_review')
  loop
    v_days := d.expiry_date - p_today;
    v_stage := case when v_days in (60, 30, 7) then 'd' || v_days
                    when v_days = 0 then 'd0'
                    when v_days < 0 and (-v_days) % 7 = 0 then 'late' || (-v_days)
                    else null end;
    continue when v_stage is null;

    v_label := initcap(replace(d.doc_type::text, '_', ' '));
    v_label := case d.doc_type::text when 'emirates_id' then 'Emirates ID' when 'labor_card' then 'Labour card'
                                     when 'health_card' then 'Health card' else v_label end;
    v_when := to_char(d.expiry_date, 'Dy DD Mon YYYY');
    v_title := case when v_days = 60 then format('Your %s expires in 2 months', v_label)
                    when v_days > 0 then format('Your %s expires in %s days', v_label, v_days)
                    when v_days = 0 then format('Your %s expires today', v_label)
                    else format('Your %s has expired', v_label) end;

    perform public.create_notification(d.entity_id, null, d.employee_id, 'document_renewal', v_title,
      format('Expiry date: %s. Open Documents and tap ‘Upload new copy’ on your %s.', v_when, v_label),
      'employee_documents', d.id, case when v_days <= 7 then 'high' else 'normal' end,
      'doc_renewal:' || d.id || ':' || v_stage);
    v_n := v_n + 1;

    insert into pg_temp._renewal_due values (d.entity_id, d.home_location_id, d.employee_name, v_label, v_days,
                                     public.is_restricted_doc_type(d.doc_type));
  end loop;

  -- One digest per HR person per day.
  for r in
    with recipients as (
      select p.id as user_id, x.entity_id, x.location_id, x.employee_name, x.label, x.days
      from pg_temp._renewal_due x
      join public.profiles p on p.is_active
        and (p.role = 'owner'
             or (p.role = 'entity_admin' and p.entity_id = x.entity_id)
             or (p.role = 'location_manager' and p.location_id = x.location_id and not x.restricted))
    )
    select user_id, min(entity_id::text)::uuid as entity_id, count(*) as n,
           string_agg(format('%s — %s %s', employee_name, label,
                             case when days > 0 then format('in %s days', days) when days = 0 then 'today'
                                  else format('expired %s days ago', -days) end),
                      '; ' order by days) as items,
           bool_or(days <= 7) as urgent
    from recipients group by user_id
  loop
    perform public.create_notification(r.entity_id, r.user_id, null, 'document_renewal_digest',
      format('%s document%s to renew', r.n, case when r.n = 1 then '' else 's' end),
      left(r.items, 900) || '. The employee has been reminded; approve the new copy when it arrives.',
      'employee_documents', null, case when r.urgent then 'high' else 'normal' end,
      'doc_renewal_digest:' || r.user_id || ':' || p_today);
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$function$;
revoke all on function public._doc_renewal_reminders(date) from public, anon, authenticated;

-- Add it as the 4th step of the daily HR reminders job.
do $patch$
declare
  v_def text := pg_get_functiondef('public.run_daily_hr_reminders(boolean)'::regprocedure);
  v_new text := v_def;
  v_parts text[][] := array[
    array[$a$    raise warning 'daily_hr_reminders: offboarding step failed: %', sqlerrm;
  end;
$a$, $a$    raise warning 'daily_hr_reminders: offboarding step failed: %', sqlerrm;
  end;

  begin
    v_n := public._doc_renewal_reminders(v_today);
    v_result := v_result || jsonb_build_object('document_renewals', jsonb_build_object('notifications', v_n));
  exception when others then
    v_failed := v_failed + 1;
    v_result := v_result || jsonb_build_object('document_renewals', jsonb_build_object('error', sqlerrm, 'sqlstate', sqlstate));
    raise warning 'daily_hr_reminders: document renewal step failed: %', sqlerrm;
  end;
$a$],
    array[$a$when v_failed = 3 then 'failed'$a$, $a$when v_failed = 4 then 'failed'$a$]
  ];
  i int;
begin
  for i in 1 .. array_length(v_parts, 1) loop
    if position(v_parts[i][1] in v_new) = 0 then
      raise exception 'run_daily_hr_reminders patch point % not found', i;
    end if;
    v_new := replace(v_new, v_parts[i][1], v_parts[i][2]);
  end loop;
  execute v_new;
end
$patch$;
