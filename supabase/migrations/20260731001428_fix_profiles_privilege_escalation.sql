-- CRITICAL FIX: staff could self-promote via `update profiles set role='owner' ...`
-- because profiles_update_own had no WITH CHECK and no column protection.
-- 1) Guard trigger: only an owner (any scope) or an entity_admin (within their own
--    entity, and never minting another owner) may change role / entity_id / location_id
--    on ANY profile row, including their own.
-- 2) Add a real admin-facing UPDATE policy so owner/entity_admin can actually manage
--    other users' role/entity/location assignments (previously impossible: the only
--    UPDATE policy was id = auth.uid()).

create or replace function public.enforce_profile_role_change_authority()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_actor_role user_role;
  v_actor_entity uuid;
begin
  if (new.role is distinct from old.role)
     or (new.entity_id is distinct from old.entity_id)
     or (new.location_id is distinct from old.location_id) then

    select role, entity_id into v_actor_role, v_actor_entity
    from public.profiles where id = auth.uid();

    if v_actor_role = 'owner' then
      return new;
    elsif v_actor_role = 'entity_admin'
      and old.entity_id = v_actor_entity
      and new.entity_id = old.entity_id
      and new.role <> 'owner' then
      return new;
    else
      raise exception 'Not authorized to change role, entity, or location assignment for this profile';
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_enforce_profile_role_change_authority on public.profiles;
create trigger trg_enforce_profile_role_change_authority
before update on public.profiles
for each row execute function public.enforce_profile_role_change_authority();

-- Admins need an actual path to manage other users' assignments; previously only
-- id = auth.uid() was permitted, so this also fixes a functional gap (HR-P01 step 3).
create policy profiles_update_by_admin
on public.profiles
for update
using (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
)
with check (
  my_role() = 'owner'
  or (my_role() = 'entity_admin' and entity_id = my_entity())
);

