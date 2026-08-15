
create table if not exists public.app_settings (
  key text primary key,
  value boolean not null,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

insert into public.app_settings (key, value)
values ('entity_admin_self_approval_enabled', false)
on conflict (key) do nothing;

alter table public.app_settings enable row level security;

drop policy if exists app_settings_select on public.app_settings;
create policy app_settings_select on public.app_settings
for select
using (true);

drop policy if exists app_settings_update on public.app_settings;
create policy app_settings_update on public.app_settings
for update
using (my_role() = 'owner')
with check (my_role() = 'owner');

create or replace function public.entity_admin_self_approval_enabled()
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select coalesce((select value from public.app_settings where key = 'entity_admin_self_approval_enabled'), false);
$$;

create or replace function public.set_entity_admin_self_approval(p_enabled boolean)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if my_role() <> 'owner' then
    raise exception 'Only the owner can change this setting';
  end if;

  update public.app_settings
    set value = p_enabled, updated_by = auth.uid(), updated_at = now()
    where key = 'entity_admin_self_approval_enabled';

  insert into audit_log (table_name, record_id, changed_by, action, new_value)
  values ('app_settings', gen_random_uuid(), auth.uid(), 'setting_changed',
    jsonb_build_object('key', 'entity_admin_self_approval_enabled', 'value', p_enabled));
end;
$$;
