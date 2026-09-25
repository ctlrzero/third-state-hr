-- ============================================================
-- W2 Access & identity.
--  * profiles.is_active: an inactive (or missing) profile makes
--    my_role()/my_entity()/my_location()/my_employee_id()/
--    my_home_location() return NULL, so every RLS policy and RPC
--    authorization check fails closed.
--  * access_grants: an owner / entity_admin pre-approves an email
--    with a role + scope. The on_auth_user_created trigger applies a
--    pending grant at sign-up (and links employees.auth_user_id).
--    A sign-up with no grant gets NO profile row => no role => the
--    app routes to /no-assignment.
--  * admin_list_user_access / admin_grant_access / admin_revoke_access.
--  * Direct UPDATE on profiles is narrowed to full_name; role/scope/
--    activation only change through the audited RPCs.
-- ============================================================

alter table public.profiles
  add column is_active boolean not null default true,
  add column deactivated_at timestamptz,
  add column deactivated_by uuid references auth.users(id) on delete set null,
  add column deactivation_reason text;

create index profiles_deactivated_by_idx on public.profiles (deactivated_by);

comment on column public.profiles.is_active is
  'false = access revoked. All my_*() helpers return NULL for an inactive profile, so RLS/RPC checks fail closed.';

-- Allow scope-less audit rows for group-wide (owner) access changes.
alter table public.audit_log drop constraint audit_log_entity_id_required_check;
alter table public.audit_log add constraint audit_log_entity_id_required_check
  check (entity_id is not null or table_name in ('app_settings', 'access_grants', 'profiles'));

-- ------------------------------------------------------------
-- Identity helpers (fail closed on inactive / missing profile)
-- ------------------------------------------------------------
create or replace function public.my_role()
returns public.user_role
language sql stable security definer
set search_path = ''
as $$
  select p.role from public.profiles p where p.id = (select auth.uid()) and p.is_active;
$$;

create or replace function public.my_entity()
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select p.entity_id from public.profiles p where p.id = (select auth.uid()) and p.is_active;
$$;

create or replace function public.my_location()
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select p.location_id from public.profiles p where p.id = (select auth.uid()) and p.is_active;
$$;

create or replace function public.my_employee_id()
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select e.id
  from public.employees e
  join public.profiles p on p.id = e.auth_user_id and p.is_active
  where e.auth_user_id = (select auth.uid())
  order by e.created_at
  limit 1;
$$;

create or replace function public.my_home_location()
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select e.home_location_id
  from public.employees e
  join public.profiles p on p.id = e.auth_user_id and p.is_active
  where e.auth_user_id = (select auth.uid())
  order by e.created_at
  limit 1;
$$;

create or replace function public.is_active_user()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce((select p.is_active from public.profiles p where p.id = (select auth.uid())), false);
$$;

revoke all on function public.is_active_user() from public, anon;
grant execute on function public.is_active_user() to authenticated;

-- Profile role/scope guard: also require the ACTOR to be active, and
-- treat is_active as a guarded column.
create or replace function public.enforce_profile_role_change_authority()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actor_role public.user_role;
  v_actor_entity uuid;
begin
  if (new.role is distinct from old.role)
     or (new.entity_id is distinct from old.entity_id)
     or (new.location_id is distinct from old.location_id)
     or (new.is_active is distinct from old.is_active) then

    select p.role, p.entity_id into v_actor_role, v_actor_entity
    from public.profiles p where p.id = auth.uid() and p.is_active;

    if new.id = auth.uid() then
      raise exception 'You cannot change your own role, scope or access status';
    elsif v_actor_role = 'owner' then
      return new;
    elsif v_actor_role = 'entity_admin'
      and old.entity_id = v_actor_entity
      and new.entity_id = old.entity_id
      and old.role <> 'owner'
      and new.role <> 'owner' then
      return new;
    else
      raise exception 'Not authorized to change role, entity, location or access status for this profile';
    end if;
  end if;

  return new;
end;
$$;

-- Direct profile writes: only full_name. Everything else via RPC.
revoke update on table public.profiles from authenticated;
grant update (full_name) on table public.profiles to authenticated;

-- ------------------------------------------------------------
-- Close policy gaps where auth.uid() was used directly (an
-- inactive user must get nothing).
-- ------------------------------------------------------------
drop policy if exists employees_select on public.employees;
create policy employees_select on public.employees
for select
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
  or ((select public.my_role()) = 'location_manager'::public.user_role and home_location_id = (select public.my_location()))
  or id = (select public.my_employee_id())
);

drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications
for select
using (
  (recipient_user_id = (select auth.uid()) and (select public.is_active_user()))
  or employee_id = (select public.my_employee_id())
  or (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
);

drop policy if exists notifications_update_self on public.notifications;
create policy notifications_update_self on public.notifications
for update
using (
  (recipient_user_id = (select auth.uid()) and (select public.is_active_user()))
  or employee_id = (select public.my_employee_id())
)
with check (
  (recipient_user_id = (select auth.uid()) and (select public.is_active_user()))
  or employee_id = (select public.my_employee_id())
);

drop policy if exists attendance_adjustments_select on public.attendance_adjustments;
create policy attendance_adjustments_select on public.attendance_adjustments
for select
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and exists (
    select 1 from public.payable_shift_records psr
    where psr.id = attendance_adjustments.payable_shift_record_id
      and psr.entity_id = (select public.my_entity())
  ))
  or ((select public.my_role()) = 'location_manager'::public.user_role and exists (
    select 1 from public.payable_shift_records psr
    where psr.id = attendance_adjustments.payable_shift_record_id
      and psr.location_id = (select public.my_location())
  ))
  or (actor_id = (select auth.uid()) and (select public.is_active_user()))
);

drop policy if exists documents_delete on public.employee_documents;
create policy documents_delete on public.employee_documents
for delete
using (
  review_status = 'pending_review'
  and is_current = false
  and (
    (submitted_by = (select auth.uid()) and (select public.is_active_user()))
    or exists (
      select 1 from public.employees e
      where e.id = employee_documents.employee_id
        and (
          (select public.my_role()) = 'owner'::public.user_role
          or ((select public.my_role()) = 'entity_admin'::public.user_role and e.entity_id = (select public.my_entity()))
          or ((select public.my_role()) = 'location_manager'::public.user_role and e.home_location_id = (select public.my_location())
              and not public.is_restricted_doc_type(employee_documents.doc_type))
        )
    )
  )
);

drop policy if exists documents_select on public.employee_documents;
create policy documents_select on public.employee_documents
for select
to authenticated
using (
  (upload_confirmed = true or submitted_by = (select auth.uid()))
  and (
    (employee_id = (select public.my_employee_id()) and public.is_active_employee(employee_id))
    or exists (
      select 1 from public.employees e
      where e.id = employee_documents.employee_id
        and (
          (select public.my_role()) = 'owner'::public.user_role
          or ((select public.my_role()) = 'entity_admin'::public.user_role and e.entity_id = (select public.my_entity()))
          or ((select public.my_role()) = 'location_manager'::public.user_role and e.home_location_id = (select public.my_location())
              and not public.is_restricted_doc_type(employee_documents.doc_type))
        )
    )
  )
);

drop policy if exists documents_insert on public.employee_documents;
create policy documents_insert on public.employee_documents
for insert
with check (
  (
    employee_id = (select public.my_employee_id())
    and public.is_active_employee(employee_id)
    and submitted_by = (select auth.uid())
    and review_status = 'pending_review' and is_current = false
    and reviewed_by is null and reviewed_at is null
    and archived_by is null and archived_at is null and rejection_reason is null
    and (supersedes_document_id is null or public.renewal_supersedes_owned_by(supersedes_document_id))
  )
  or (
    submitted_by = (select auth.uid())
    and review_status = 'pending_review' and is_current = false
    and reviewed_by is null and reviewed_at is null
    and archived_by is null and archived_at is null and rejection_reason is null
    and exists (
      select 1 from public.employees e
      where e.id = employee_documents.employee_id
        and (
          (select public.my_role()) = 'owner'::public.user_role
          or ((select public.my_role()) = 'entity_admin'::public.user_role and e.entity_id = (select public.my_entity()))
          or ((select public.my_role()) = 'location_manager'::public.user_role and e.home_location_id = (select public.my_location())
              and not public.is_restricted_doc_type(employee_documents.doc_type))
        )
    )
  )
);

drop policy if exists doc_bucket_delete on storage.objects;
create policy doc_bucket_delete on storage.objects
for delete
using (
  bucket_id = 'employee-documents'
  and exists (
    select 1
    from public.employee_documents d
    join public.employees e on e.id = d.employee_id
    where d.storage_path = objects.name
      and d.review_status = 'pending_review'
      and d.is_current = false
      and (
        (d.submitted_by = (select auth.uid()) and (select public.is_active_user()))
        or (select public.my_role()) = 'owner'::public.user_role
        or ((select public.my_role()) = 'entity_admin'::public.user_role and e.entity_id = (select public.my_entity()))
        or ((select public.my_role()) = 'location_manager'::public.user_role and e.home_location_id = (select public.my_location())
            and not public.is_restricted_doc_type(d.doc_type))
      )
  )
);

drop policy if exists interviews_interviewer_select on public.interviews;
create policy interviews_interviewer_select on public.interviews
for select
to authenticated
using (
  interviewer_id = (select auth.uid())
  and public.is_active_employee((select public.my_employee_id()))
  and public.requisition_entity_for_interview(id) = (select public.my_entity())
  and public.is_interview_within_visibility_window(scheduled_at, public.interview_feedback_status_for(id))
);

drop policy if exists interview_feedback_interviewer_select on public.interview_feedback;
create policy interview_feedback_interviewer_select on public.interview_feedback
for select
using (
  submitted_by = (select auth.uid())
  and (select public.is_active_user())
  and exists (
    select 1 from public.interviews iv
    where iv.id = interview_feedback.interview_id
      and iv.interviewer_id = (select auth.uid())
  )
);

-- ------------------------------------------------------------
-- access_grants
-- ------------------------------------------------------------
create table public.access_grants (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  role public.user_role not null,
  entity_id uuid references public.entities(id),
  location_id uuid references public.locations(id),
  employee_id uuid references public.employees(id),
  status text not null default 'pending' check (status in ('pending', 'applied', 'revoked')),
  granted_by uuid references auth.users(id) on delete set null,
  granted_at timestamptz not null default now(),
  applied_user_id uuid references auth.users(id) on delete set null,
  applied_at timestamptz,
  revoked_by uuid references auth.users(id) on delete set null,
  revoked_at timestamptz,
  revoke_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint access_grants_email_format_check check (email = lower(btrim(email)) and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  constraint access_grants_scope_check check (
    (role = 'owner' and entity_id is null and location_id is null and employee_id is null)
    or (role = 'entity_admin' and entity_id is not null and location_id is null)
    or (role = 'location_manager' and entity_id is not null and location_id is not null)
    or (role = 'staff' and entity_id is not null and employee_id is not null)
  )
);

comment on table public.access_grants is
  'Pre-approved logins. One pending grant per email. Applied at sign-up by handle_new_user(), or immediately by admin_grant_access() when the auth user already exists. Writes only via admin_grant_access/admin_revoke_access.';

create unique index access_grants_one_pending_per_email_uq on public.access_grants (email) where status = 'pending';
create index access_grants_entity_idx on public.access_grants (entity_id);
create index access_grants_location_idx on public.access_grants (location_id);
create index access_grants_employee_idx on public.access_grants (employee_id);
create index access_grants_granted_by_idx on public.access_grants (granted_by);
create index access_grants_applied_user_idx on public.access_grants (applied_user_id);
create index access_grants_revoked_by_idx on public.access_grants (revoked_by);

alter table public.access_grants enable row level security;

create policy access_grants_select on public.access_grants
for select
to authenticated
using (
  (select public.my_role()) = 'owner'::public.user_role
  or ((select public.my_role()) = 'entity_admin'::public.user_role and entity_id = (select public.my_entity()))
);

grant select on table public.access_grants to authenticated;

-- ------------------------------------------------------------
-- Internal: apply one pending grant to an auth user.
-- ------------------------------------------------------------
create or replace function public._apply_access_grant(p_grant_id uuid, p_user_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  g public.access_grants;
  v_loc uuid;
  v_name text;
begin
  select * into g from public.access_grants where id = p_grant_id for update;
  if g.id is null or g.status <> 'pending' then
    raise exception 'Access grant % is not pending', p_grant_id;
  end if;

  v_loc := g.location_id;

  if g.employee_id is not null then
    update public.employees
       set auth_user_id = p_user_id
     where id = g.employee_id
       and (auth_user_id is null or auth_user_id = p_user_id);
    if not found then
      raise exception 'Employee % is already linked to a different login', g.employee_id;
    end if;
    select coalesce(g.location_id, e.home_location_id), e.full_name
      into v_loc, v_name
      from public.employees e where e.id = g.employee_id;
  end if;

  if g.role in ('owner', 'entity_admin') then
    v_loc := null;
  end if;

  if v_name is null then
    select nullif(u.raw_user_meta_data->>'full_name', '') into v_name from auth.users u where u.id = p_user_id;
  end if;

  insert into public.profiles (id, full_name, role, entity_id, location_id, is_active)
  values (p_user_id, v_name, g.role, g.entity_id, v_loc, true)
  on conflict (id) do update set
    role = excluded.role,
    entity_id = excluded.entity_id,
    location_id = excluded.location_id,
    is_active = true,
    deactivated_at = null,
    deactivated_by = null,
    deactivation_reason = null,
    full_name = coalesce(public.profiles.full_name, excluded.full_name);

  -- One live grant per user: close any earlier applied grant.
  update public.access_grants
     set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(),
         revoke_reason = 'Superseded by grant ' || g.id::text, updated_at = now()
   where applied_user_id = p_user_id and status = 'applied' and id <> g.id;

  update public.access_grants
     set status = 'applied', applied_user_id = p_user_id, applied_at = now(), updated_at = now()
   where id = g.id;

  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('access_grants', g.id, auth.uid(), 'access_grant_applied',
    jsonb_build_object('user_id', p_user_id, 'role', g.role, 'location_id', v_loc, 'employee_id', g.employee_id),
    g.entity_id, v_loc, g.employee_id);
end;
$$;

revoke all on function public._apply_access_grant(uuid, uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- Sign-up hook: apply a pending grant, otherwise create nothing.
-- A failure to apply (e.g. employee already linked) never blocks
-- the sign-up itself; the user simply lands on /no-assignment.
-- ------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_grant uuid;
begin
  if new.email is null then
    return new;
  end if;

  select g.id into v_grant
  from public.access_grants g
  where g.email = lower(btrim(new.email)) and g.status = 'pending'
  order by g.granted_at desc
  limit 1;

  if v_grant is not null then
    begin
      perform public._apply_access_grant(v_grant, new.id);
    exception when others then
      raise warning 'handle_new_user: could not apply access grant % for %: %', v_grant, new.id, sqlerrm;
    end;
  end if;

  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;

-- ------------------------------------------------------------
-- admin_list_user_access
-- ------------------------------------------------------------
create or replace function public.admin_list_user_access(p_entity_id uuid)
returns table (
  user_id uuid,
  email text,
  full_name text,
  role public.user_role,
  entity_id uuid,
  location_id uuid,
  employee_id uuid,
  is_active boolean,
  last_sign_in_at timestamptz,
  is_pending boolean,
  grant_id uuid
)
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_entity uuid;
begin
  if v_role is null or v_role not in ('owner', 'entity_admin') then
    raise exception 'Not authorized to view user access' using errcode = '42501';
  end if;

  if v_role = 'entity_admin' then
    if p_entity_id is not null and p_entity_id is distinct from public.my_entity() then
      raise exception 'Entity admins can only view their own entity' using errcode = '42501';
    end if;
    v_entity := public.my_entity();
  else
    v_entity := p_entity_id;
  end if;

  return query
  select p.id, u.email::text, p.full_name, p.role, p.entity_id, p.location_id,
         emp.id, p.is_active, u.last_sign_in_at, false, gr.id
  from public.profiles p
  join auth.users u on u.id = p.id
  left join lateral (
    select e.id from public.employees e where e.auth_user_id = p.id order by e.created_at limit 1
  ) emp on true
  left join lateral (
    select g.id from public.access_grants g
    where g.applied_user_id = p.id and g.status = 'applied'
    order by g.applied_at desc limit 1
  ) gr on true
  where v_entity is null or p.entity_id = v_entity

  union all

  select null::uuid, g.email, emp.full_name, g.role, g.entity_id, g.location_id,
         g.employee_id, false, null::timestamptz, true, g.id
  from public.access_grants g
  left join public.employees emp on emp.id = g.employee_id
  where g.status = 'pending'
    and (v_entity is null or g.entity_id = v_entity)

  union all

  -- Owner, unfiltered: signed-up accounts that hold no role at all.
  select u.id, u.email::text, nullif(u.raw_user_meta_data->>'full_name', ''), null::public.user_role,
         null::uuid, null::uuid, null::uuid, false, u.last_sign_in_at, false, null::uuid
  from auth.users u
  where v_role = 'owner' and v_entity is null
    and not exists (select 1 from public.profiles p2 where p2.id = u.id)

  order by 10 desc, 3 nulls last, 2;
end;
$$;

revoke all on function public.admin_list_user_access(uuid) from public, anon;
grant execute on function public.admin_list_user_access(uuid) to authenticated;

-- ------------------------------------------------------------
-- admin_grant_access
-- ------------------------------------------------------------
create or replace function public.admin_grant_access(
  p_email text,
  p_role public.user_role,
  p_entity_id uuid,
  p_location_id uuid,
  p_employee_id uuid
)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_email text := lower(btrim(p_email));
  v_entity public.entities;
  v_loc public.locations;
  v_emp public.employees;
  v_user_id uuid;
  v_target public.profiles;
  v_id uuid;
begin
  if v_role is null or v_role not in ('owner', 'entity_admin') then
    raise exception 'Not authorized to grant access' using errcode = '42501';
  end if;
  if v_email is null or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'A valid email address is required' using errcode = '22023';
  end if;
  if p_role is null then
    raise exception 'A role is required' using errcode = '22023';
  end if;

  if v_role = 'entity_admin' then
    if p_role = 'owner' then
      raise exception 'Entity admins cannot grant the owner role' using errcode = '42501';
    end if;
    if p_entity_id is distinct from public.my_entity() then
      raise exception 'Entity admins can only grant access within their own entity' using errcode = '42501';
    end if;
  end if;

  -- Scope shape per role
  if p_role = 'owner' then
    if p_entity_id is not null or p_location_id is not null or p_employee_id is not null then
      raise exception 'Owner access is group-wide: entity, location and employee must be empty' using errcode = '22023';
    end if;
  else
    select * into v_entity from public.entities where id = p_entity_id;
    if v_entity.id is null then
      raise exception 'A valid entity is required for this role' using errcode = '22023';
    end if;
    if not v_entity.is_active then
      raise exception 'Cannot grant access to an inactive entity' using errcode = '22023';
    end if;
  end if;

  if p_role = 'entity_admin' and p_location_id is not null then
    raise exception 'Entity admin access is entity-wide: location must be empty' using errcode = '22023';
  end if;
  if p_role = 'location_manager' and p_location_id is null then
    raise exception 'A location is required for a location manager' using errcode = '22023';
  end if;
  if p_location_id is not null then
    select * into v_loc from public.locations where id = p_location_id;
    if v_loc.id is null or v_loc.entity_id is distinct from p_entity_id then
      raise exception 'Location does not belong to the selected entity' using errcode = '22023';
    end if;
    if not v_loc.is_active then
      raise exception 'Cannot grant access to an inactive location' using errcode = '22023';
    end if;
  end if;

  if p_role = 'staff' and p_employee_id is null then
    raise exception 'Staff access must be linked to an employee record' using errcode = '22023';
  end if;
  if p_employee_id is not null then
    select * into v_emp from public.employees where id = p_employee_id;
    if v_emp.id is null or v_emp.entity_id is distinct from p_entity_id then
      raise exception 'Employee does not belong to the selected entity' using errcode = '22023';
    end if;
    if v_emp.employment_status = 'inactive' then
      raise exception 'Cannot grant access to an inactive employee' using errcode = '22023';
    end if;
    if p_role = 'staff' and p_location_id is not null and v_emp.home_location_id is distinct from p_location_id then
      raise exception 'Staff location must match the employee''s home location' using errcode = '22023';
    end if;
  end if;

  select u.id into v_user_id from auth.users u where lower(u.email) = v_email limit 1;

  if v_user_id is not null and v_user_id = auth.uid() then
    raise exception 'You cannot change your own access' using errcode = '42501';
  end if;
  if v_emp.id is not null and v_emp.auth_user_id is not null and v_emp.auth_user_id is distinct from v_user_id then
    raise exception 'This employee is already linked to a different login' using errcode = '23505';
  end if;

  if v_user_id is not null and v_role = 'entity_admin' then
    select * into v_target from public.profiles where id = v_user_id;
    if v_target.id is not null and (v_target.role = 'owner' or v_target.entity_id is distinct from public.my_entity()) then
      raise exception 'This login belongs to an owner or another entity' using errcode = '42501';
    end if;
  end if;

  -- An entity admin may not silently displace another entity's pending grant.
  if v_role = 'entity_admin' and exists (
    select 1 from public.access_grants g
    where g.email = v_email and g.status = 'pending' and g.entity_id is distinct from public.my_entity()
  ) then
    raise exception 'A pending grant for this email exists in another scope' using errcode = '42501';
  end if;

  update public.access_grants
     set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(),
         revoke_reason = 'Superseded by a newer grant', updated_at = now()
   where email = v_email and status = 'pending';

  insert into public.access_grants (email, role, entity_id, location_id, employee_id, granted_by)
  values (v_email, p_role, p_entity_id, p_location_id, p_employee_id, auth.uid())
  returning id into v_id;

  insert into public.audit_log (table_name, record_id, changed_by, action, new_value, entity_id, location_id, employee_id)
  values ('access_grants', v_id, auth.uid(), 'access_granted',
    jsonb_build_object('email', v_email, 'role', p_role, 'entity_id', p_entity_id,
                       'location_id', p_location_id, 'employee_id', p_employee_id,
                       'existing_user', v_user_id is not null),
    p_entity_id, p_location_id, p_employee_id);

  if v_user_id is not null then
    perform public._apply_access_grant(v_id, v_user_id);
  end if;

  return v_id;
end;
$$;

revoke all on function public.admin_grant_access(text, public.user_role, uuid, uuid, uuid) from public, anon;
grant execute on function public.admin_grant_access(text, public.user_role, uuid, uuid, uuid) to authenticated;

-- ------------------------------------------------------------
-- admin_revoke_access: exactly one of p_user_id / p_grant_id.
-- ------------------------------------------------------------
create or replace function public.admin_revoke_access(p_user_id uuid, p_grant_id uuid, p_reason text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_role public.user_role := public.my_role();
  v_reason text := nullif(btrim(p_reason), '');
  g public.access_grants;
  v_user uuid := p_user_id;
  v_prof public.profiles;
begin
  if v_role is null or v_role not in ('owner', 'entity_admin') then
    raise exception 'Not authorized to revoke access' using errcode = '42501';
  end if;
  if (p_user_id is null) = (p_grant_id is null) then
    raise exception 'Provide exactly one of p_user_id or p_grant_id' using errcode = '22023';
  end if;
  if v_reason is null then
    raise exception 'A reason is required to revoke access' using errcode = '22023';
  end if;

  if p_grant_id is not null then
    select * into g from public.access_grants where id = p_grant_id for update;
    if g.id is null then
      raise exception 'Access grant not found' using errcode = 'P0002';
    end if;
    if not (v_role = 'owner' or (g.entity_id = public.my_entity() and g.role <> 'owner')) then
      raise exception 'Not authorized to revoke this grant' using errcode = '42501';
    end if;
    if g.status = 'revoked' then
      raise exception 'This grant is already revoked' using errcode = '22023';
    end if;
    if g.status = 'pending' then
      update public.access_grants
         set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), revoke_reason = v_reason, updated_at = now()
       where id = g.id;
      insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id, employee_id)
      values ('access_grants', g.id, auth.uid(), 'access_grant_revoked',
        jsonb_build_object('status', 'pending'),
        jsonb_build_object('status', 'revoked', 'email', g.email, 'role', g.role, 'reason', v_reason),
        g.entity_id, g.location_id, g.employee_id);
      return;
    end if;
    -- Applied grant: revoke the user it was applied to.
    v_user := g.applied_user_id;
    if v_user is null then
      raise exception 'The login this grant was applied to no longer exists' using errcode = 'P0002';
    end if;
  end if;

  if v_user = auth.uid() then
    raise exception 'You cannot revoke your own access' using errcode = '42501';
  end if;

  select * into v_prof from public.profiles where id = v_user for update;
  if v_prof.id is null then
    raise exception 'This login has no access to revoke' using errcode = 'P0002';
  end if;
  if not (v_role = 'owner' or (v_prof.entity_id = public.my_entity() and v_prof.role <> 'owner')) then
    raise exception 'Not authorized to revoke this login' using errcode = '42501';
  end if;
  if not v_prof.is_active then
    raise exception 'This login is already inactive' using errcode = '22023';
  end if;

  update public.profiles
     set is_active = false, deactivated_at = now(), deactivated_by = auth.uid(), deactivation_reason = v_reason
   where id = v_user;

  update public.access_grants
     set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), revoke_reason = v_reason, updated_at = now()
   where applied_user_id = v_user and status = 'applied';

  insert into public.audit_log (table_name, record_id, changed_by, action, old_value, new_value, entity_id, location_id)
  values ('profiles', v_user, auth.uid(), 'access_revoked',
    jsonb_build_object('is_active', true, 'role', v_prof.role),
    jsonb_build_object('is_active', false, 'reason', v_reason),
    v_prof.entity_id, v_prof.location_id);
end;
$$;

revoke all on function public.admin_revoke_access(uuid, uuid, text) from public, anon;
grant execute on function public.admin_revoke_access(uuid, uuid, text) to authenticated;
