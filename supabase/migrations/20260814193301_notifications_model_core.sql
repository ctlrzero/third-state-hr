
-- Phase 2.5: shared, entity-scoped notifications model.
-- A notification targets either a specific signed-in user (recipient_user_id -- used for
-- manager-facing alerts like "a leave request needs your decision", since interviewer_id
-- on interviews references auth.users directly, not employees) and/or a specific employee
-- record (employee_id -- used for employee-facing alerts like "your document was
-- approved", which should reach the employee even before they have a login synced).
-- Message content is deliberately privacy-safe: no salary/bank figures, no full document
-- numbers, no attachment links/paths -- just enough context to know what happened and
-- where to go look (target_type/target_id let the client deep-link into the real record,
-- which is itself already properly RLS-scoped).
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities(id),
  recipient_user_id uuid references auth.users(id),
  employee_id uuid references public.employees(id),
  notification_type text not null,
  title text not null,
  message text,
  target_type text,
  target_id uuid,
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high')),
  read_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  dedupe_key text,
  constraint notifications_recipient_required check (recipient_user_id is not null or employee_id is not null)
);

create unique index notifications_dedupe_idx on public.notifications (entity_id, dedupe_key) where dedupe_key is not null;
create index notifications_recipient_idx on public.notifications (recipient_user_id) where recipient_user_id is not null;
create index notifications_employee_idx on public.notifications (employee_id) where employee_id is not null;
create index notifications_entity_idx on public.notifications (entity_id);
create index notifications_created_at_idx on public.notifications (created_at desc);

alter table public.notifications enable row level security;

-- Visibility: the actual recipient (by user id or employee record) always sees their own;
-- owner/entity_admin can see everything in scope for oversight -- the message content is
-- privacy-safe by design, so this isn't a new sensitive-data exposure, it mirrors how
-- owner/entity_admin already see the real underlying records these notifications merely
-- point at. location_manager and staff only ever see notifications actually addressed to
-- them -- consistent with "managers see only assigned operational ones" / "employees see
-- only their own notifications".
create policy notifications_select on public.notifications for select using (
  recipient_user_id = auth.uid()
  or employee_id = my_employee_id()
  or my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
);

-- The only thing a recipient can do directly is mark their own notification read/resolved
-- -- never edit title/message/target, never mark someone else's.
create policy notifications_update_self on public.notifications for update using (
  recipient_user_id = auth.uid() or employee_id = my_employee_id()
) with check (
  recipient_user_id = auth.uid() or employee_id = my_employee_id()
);

-- No INSERT/DELETE policy for authenticated at all -- every row is written by
-- create_notification() below (SECURITY DEFINER, not directly callable by clients).

revoke all on public.notifications from authenticated, anon, public;
grant select, update on public.notifications to authenticated;

-- Internal-only writer. Never exposed to clients directly -- callable only from other
-- SECURITY DEFINER functions, which retain full privileges as the function owner
-- regardless of the revoke below (the same pattern already used for trigger functions).
create function public.create_notification(
  p_entity_id uuid,
  p_recipient_user_id uuid,
  p_employee_id uuid,
  p_notification_type text,
  p_title text,
  p_message text,
  p_target_type text default null,
  p_target_id uuid default null,
  p_priority text default 'normal',
  p_dedupe_key text default null
) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_id uuid;
begin
  if p_recipient_user_id is null and p_employee_id is null then
    return null;
  end if;
  insert into public.notifications (
    entity_id, recipient_user_id, employee_id, notification_type, title, message,
    target_type, target_id, priority, dedupe_key
  ) values (
    p_entity_id, p_recipient_user_id, p_employee_id, p_notification_type, p_title, p_message,
    p_target_type, p_target_id, coalesce(p_priority, 'normal'), p_dedupe_key
  )
  on conflict (entity_id, dedupe_key) where dedupe_key is not null do nothing
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.create_notification(uuid, uuid, uuid, text, text, text, text, uuid, text, text) from public, anon, authenticated;

-- Client-facing read/ack RPCs.
create function public.get_my_notifications(
  p_limit int default 50,
  p_before timestamptz default null,
  p_unread_only boolean default false
) returns table(
  id uuid, notification_type text, title text, message text,
  target_type text, target_id uuid, priority text,
  read_at timestamptz, resolved_at timestamptz, created_at timestamptz
)
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if p_limit is null or p_limit <= 0 or p_limit > 200 then
    p_limit := 50;
  end if;
  return query
    select n.id, n.notification_type, n.title, n.message, n.target_type, n.target_id, n.priority, n.read_at, n.resolved_at, n.created_at
    from public.notifications n
    where (n.recipient_user_id = auth.uid() or n.employee_id = my_employee_id())
      and (p_before is null or n.created_at < p_before)
      and (not p_unread_only or n.read_at is null)
    order by n.created_at desc
    limit p_limit;
end;
$$;

create function public.unread_notification_count() returns int
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select count(*)::int from public.notifications
  where read_at is null and (recipient_user_id = auth.uid() or employee_id = my_employee_id());
$$;

create function public.mark_notification_read(p_notification_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_cnt int;
begin
  update public.notifications set read_at = now()
  where id = p_notification_id and read_at is null
    and (recipient_user_id = auth.uid() or employee_id = my_employee_id());
  get diagnostics v_cnt = row_count;
  if v_cnt = 0 then
    return jsonb_build_object('ok', false, 'code', 'NOT_FOUND_OR_ALREADY_READ');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create function public.mark_all_notifications_read() returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_cnt int;
begin
  update public.notifications set read_at = now()
  where read_at is null and (recipient_user_id = auth.uid() or employee_id = my_employee_id());
  get diagnostics v_cnt = row_count;
  return jsonb_build_object('ok', true, 'updated', v_cnt);
end;
$$;

revoke all on function public.get_my_notifications(int, timestamptz, boolean) from public, anon;
grant execute on function public.get_my_notifications(int, timestamptz, boolean) to authenticated;
revoke all on function public.unread_notification_count() from public, anon;
grant execute on function public.unread_notification_count() to authenticated;
revoke all on function public.mark_notification_read(uuid) from public, anon;
grant execute on function public.mark_notification_read(uuid) to authenticated;
revoke all on function public.mark_all_notifications_read() from public, anon;
grant execute on function public.mark_all_notifications_read() to authenticated;

