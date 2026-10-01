-- In-app Help Centre: articles live in the database, edited by Owner / Company Admin only.
-- Readers get published articles filtered to their role through SECURITY DEFINER RPCs; tables are not directly accessible.

create table if not exists public.help_articles (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title text not null,
  category text not null check (category in ('getting-started','employee','manager','admin')),
  audience text[] not null default '{}',
  summary text not null default '',
  body_md text not null default '',
  related text[] not null default '{}',
  route text,
  status text not null default 'draft' check (status in ('draft','published','archived')),
  last_reviewed date,
  current_version int not null default 0,
  -- Unpublished edits to an article (jsonb of the editable fields); live fields above are what readers see.
  draft jsonb,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

create table if not exists public.help_article_versions (
  id uuid primary key default gen_random_uuid(),
  article_id uuid not null references public.help_articles(id) on delete cascade,
  version int not null,
  snapshot jsonb not null,
  change_note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (article_id, version)
);

create index if not exists help_articles_fts_idx on public.help_articles
  using gin (to_tsvector('english', title || ' ' || summary || ' ' || body_md));

alter table public.help_articles enable row level security;
alter table public.help_article_versions enable row level security;
revoke all on public.help_articles from public, anon, authenticated;
revoke all on public.help_article_versions from public, anon, authenticated;

-- Private bucket for screenshots; only signed-in users with an active role can read, admins can write.
insert into storage.buckets (id, name, public) values ('help-media', 'help-media', false)
on conflict (id) do update set public = false;

create or replace function public._help_is_admin() returns boolean
language sql stable security definer set search_path to '' as $$
  select coalesce(public.my_role()::text in ('owner','entity_admin'), false)
$$;
revoke all on function public._help_is_admin() from public, anon;
grant execute on function public._help_is_admin() to authenticated;

drop policy if exists help_media_read on storage.objects;
create policy help_media_read on storage.objects for select to authenticated
  using (bucket_id = 'help-media' and public.my_role() is not null);
drop policy if exists help_media_write on storage.objects;
create policy help_media_write on storage.objects for insert to authenticated
  with check (bucket_id = 'help-media' and public._help_is_admin());
drop policy if exists help_media_update on storage.objects;
create policy help_media_update on storage.objects for update to authenticated
  using (bucket_id = 'help-media' and public._help_is_admin())
  with check (bucket_id = 'help-media' and public._help_is_admin());
drop policy if exists help_media_delete on storage.objects;
create policy help_media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'help-media' and public._help_is_admin());

-- Shared checks (internal; not callable by API roles).
create or replace function public._help_require_active() returns void
language plpgsql stable security definer set search_path to '' as $$
begin
  if auth.uid() is not null and public.my_role() is null then
    raise exception using errcode = '42501', message = 'Not authorized: your access is not active';
  end if;
end $$;

create or replace function public._help_require_admin() returns void
language plpgsql stable security definer set search_path to '' as $$
begin
  perform public._help_require_active();
  if not public._help_is_admin() then
    raise exception using errcode = '42501', message = 'Only an Owner or Company Admin can manage help articles';
  end if;
end $$;

create or replace function public._help_visible(p_audience text[]) returns boolean
language sql stable security definer set search_path to '' as $$
  select coalesce(public.my_role()::text in ('owner','entity_admin') or public.my_role()::text = any(p_audience), false)
$$;
revoke all on function public._help_require_active() from public, anon, authenticated;
revoke all on function public._help_require_admin() from public, anon, authenticated;
revoke all on function public._help_visible(text[]) from public, anon, authenticated;

-- ===== Reader RPCs =====
create or replace function public.help_list_articles() returns table (
  slug text, title text, category text, audience text[], summary text, related text[], route text, last_reviewed date, updated_at timestamptz)
language plpgsql stable security definer set search_path to '' as $$
begin
  perform public._help_require_active();
  return query
    select a.slug, a.title, a.category, a.audience, a.summary, a.related, a.route, a.last_reviewed, a.updated_at
    from public.help_articles a
    where a.status = 'published' and public._help_visible(a.audience)
    order by a.title;
end $$;

create or replace function public.help_get_article(p_slug text) returns table (
  slug text, title text, category text, audience text[], summary text, body_md text, related text[], route text, last_reviewed date, updated_at timestamptz)
language plpgsql stable security definer set search_path to '' as $$
begin
  perform public._help_require_active();
  return query
    select a.slug, a.title, a.category, a.audience, a.summary, a.body_md, a.related, a.route, a.last_reviewed, a.updated_at
    from public.help_articles a
    where a.slug = p_slug and a.status = 'published' and public._help_visible(a.audience);
end $$;

-- Full-text first (best matches on top); ILIKE catches partial words and short queries.
create or replace function public.help_search(p_query text) returns table (
  slug text, title text, category text, summary text, snippet text, rank real)
language plpgsql stable security definer set search_path to '' as $$
declare
  q text := btrim(coalesce(p_query, ''));
  tsq tsquery;
  pat text;
begin
  perform public._help_require_active();
  if length(q) < 2 then return; end if;
  tsq := websearch_to_tsquery('english', q);
  pat := '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  return query
    select a.slug, a.title, a.category, a.summary,
      case
        when to_tsvector('english', a.body_md) @@ tsq
          then ts_headline('english', a.body_md, tsq, 'StartSel=[[, StopSel=]], MaxFragments=1, MaxWords=28, MinWords=12')
        when a.body_md ilike pat
          then substr(a.body_md, greatest(position(lower(q) in lower(a.body_md)) - 60, 1), 160)
        else a.summary
      end as snippet,
      (ts_rank(setweight(to_tsvector('english', a.title), 'A') || setweight(to_tsvector('english', a.summary), 'B')
               || setweight(to_tsvector('english', a.body_md), 'C'), tsq)
        + case when a.title ilike pat then 0.5 else 0 end)::real as rank
    from public.help_articles a
    where a.status = 'published' and public._help_visible(a.audience)
      and (to_tsvector('english', a.title || ' ' || a.summary || ' ' || a.body_md) @@ tsq
           or a.title ilike pat or a.summary ilike pat or a.body_md ilike pat)
    order by 6 desc, a.title
    limit 30;
end $$;

-- ===== Admin RPCs =====
create or replace function public.help_admin_list() returns table (
  slug text, title text, category text, status text, audience text[], last_reviewed date,
  current_version int, has_draft boolean, updated_at timestamptz)
language plpgsql stable security definer set search_path to '' as $$
begin
  perform public._help_require_admin();
  return query
    select a.slug, a.title, a.category, a.status, a.audience, a.last_reviewed, a.current_version,
           a.draft is not null, a.updated_at
    from public.help_articles a order by a.title;
end $$;

create or replace function public.help_admin_get(p_slug text) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare a public.help_articles;
begin
  perform public._help_require_admin();
  select * into a from public.help_articles where slug = p_slug;
  if not found then raise exception using errcode = 'P0002', message = 'Article not found'; end if;
  return jsonb_build_object(
    'slug', a.slug, 'status', a.status, 'last_reviewed', a.last_reviewed, 'current_version', a.current_version,
    'updated_at', a.updated_at,
    'live', jsonb_build_object('title', a.title, 'category', a.category, 'audience', to_jsonb(a.audience),
      'summary', a.summary, 'body_md', a.body_md, 'related', to_jsonb(a.related), 'route', a.route),
    'draft', a.draft);
end $$;

create or replace function public.help_admin_save_draft(
  p_slug text, p_title text, p_category text, p_audience text[], p_summary text, p_body_md text,
  p_related text[], p_route text) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare
  d jsonb;
  a public.help_articles;
begin
  perform public._help_require_admin();
  if p_slug is null or p_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception using errcode = '22023', message = 'The web address must use lowercase letters, numbers and dashes only';
  end if;
  if btrim(coalesce(p_title, '')) = '' then raise exception using errcode = '22023', message = 'Please add a title'; end if;
  if p_category is null or p_category not in ('getting-started','employee','manager','admin') then
    raise exception using errcode = '22023', message = 'Please choose a category';
  end if;
  if exists (select 1 from unnest(coalesce(p_audience, '{}')) x where x not in ('staff','shift_supervisor','location_manager','entity_admin','owner')) then
    raise exception using errcode = '22023', message = 'Unknown audience';
  end if;
  d := jsonb_build_object('title', btrim(p_title), 'category', p_category, 'audience', to_jsonb(coalesce(p_audience, '{}')),
    'summary', coalesce(p_summary, ''), 'body_md', coalesce(p_body_md, ''), 'related', to_jsonb(coalesce(p_related, '{}')),
    'route', nullif(btrim(coalesce(p_route, '')), ''));
  select * into a from public.help_articles where slug = p_slug;
  if not found then
    insert into public.help_articles (slug, title, category, audience, summary, body_md, related, route, status, draft, updated_by)
    values (p_slug, btrim(p_title), p_category, coalesce(p_audience, '{}'), coalesce(p_summary, ''), coalesce(p_body_md, ''),
            coalesce(p_related, '{}'), nullif(btrim(coalesce(p_route, '')), ''), 'draft', d, auth.uid());
  else
    update public.help_articles set draft = d, updated_by = auth.uid(), updated_at = now() where slug = p_slug;
  end if;
  return jsonb_build_object('ok', true, 'slug', p_slug);
end $$;

create or replace function public.help_admin_publish(p_slug text, p_change_note text, p_last_reviewed date default null)
returns jsonb
language plpgsql security definer set search_path to '' as $$
declare
  a public.help_articles;
  d jsonb;
  v int;
begin
  perform public._help_require_admin();
  select * into a from public.help_articles where slug = p_slug for update;
  if not found then raise exception using errcode = 'P0002', message = 'Article not found'; end if;
  if a.draft is null and a.status = 'published' then
    raise exception using errcode = '22023', message = 'There are no unpublished changes to publish';
  end if;
  d := coalesce(a.draft, jsonb_build_object('title', a.title, 'category', a.category, 'audience', to_jsonb(a.audience),
    'summary', a.summary, 'body_md', a.body_md, 'related', to_jsonb(a.related), 'route', a.route));
  v := a.current_version + 1;
  update public.help_articles set
    title = d->>'title', category = d->>'category',
    audience = coalesce(array(select jsonb_array_elements_text(d->'audience')), '{}'),
    summary = d->>'summary', body_md = d->>'body_md',
    related = coalesce(array(select jsonb_array_elements_text(d->'related')), '{}'),
    route = d->>'route', status = 'published', draft = null, current_version = v,
    last_reviewed = coalesce(p_last_reviewed, current_date), updated_by = auth.uid(), updated_at = now()
  where id = a.id;
  insert into public.help_article_versions (article_id, version, snapshot, change_note, created_by)
  values (a.id, v, d, nullif(btrim(coalesce(p_change_note, '')), ''), auth.uid());
  return jsonb_build_object('ok', true, 'version', v);
end $$;

create or replace function public.help_admin_mark_reviewed(p_slug text) returns jsonb
language plpgsql security definer set search_path to '' as $$
begin
  perform public._help_require_admin();
  update public.help_articles set last_reviewed = current_date, updated_by = auth.uid(), updated_at = now() where slug = p_slug;
  if not found then raise exception using errcode = 'P0002', message = 'Article not found'; end if;
  return jsonb_build_object('ok', true, 'last_reviewed', current_date);
end $$;

create or replace function public.help_admin_versions(p_slug text) returns table (
  version int, change_note text, created_at timestamptz, created_by_name text, snapshot jsonb)
language plpgsql stable security definer set search_path to '' as $$
begin
  perform public._help_require_admin();
  return query
    select v.version, v.change_note, v.created_at,
           (select p.full_name from public.profiles p where p.id = v.created_by) as created_by_name, v.snapshot
    from public.help_article_versions v join public.help_articles a on a.id = v.article_id
    where a.slug = p_slug order by v.version desc;
end $$;

create or replace function public.help_admin_restore_version(p_slug text, p_version int) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s jsonb;
begin
  perform public._help_require_admin();
  select v.snapshot into s from public.help_article_versions v join public.help_articles a on a.id = v.article_id
   where a.slug = p_slug and v.version = p_version;
  if s is null then raise exception using errcode = 'P0002', message = 'Version not found'; end if;
  update public.help_articles set draft = s, updated_by = auth.uid(), updated_at = now() where slug = p_slug;
  return jsonb_build_object('ok', true, 'restored_version', p_version);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'help_list_articles()', 'help_get_article(text)', 'help_search(text)', 'help_admin_list()', 'help_admin_get(text)',
    'help_admin_save_draft(text,text,text,text[],text,text,text[],text)', 'help_admin_publish(text,text,date)',
    'help_admin_mark_reviewed(text)', 'help_admin_versions(text)', 'help_admin_restore_version(text,int)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
