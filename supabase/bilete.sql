-- =====================================================================
-- Bilete: album på medlemssida + utval som blir vist på framsida
-- Køyr heile fila i Supabase → SQL Editor ETTER tilgang.sql.
-- Fila kan køyrast fleire gongar.
--
-- Kay 2026-11-26:
--  * Medlemmer lastar opp bilete i album (t.d. Hygge, MC-skru, Oppussing).
--  * Bilete med hake «Vis på framsida» blir vist på den opne sida under
--    «Velkomen til support-sida for Vikenes MC».
--  * Haken blir sett av dei med tilgang til «nyheiter» (dei som styrer det
--    offentlege innhaldet) – President har alltid.
--  * Bileta ligg i ein privat bucket. Framsida får berre sjå delte bilete.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bilete', 'bilete', false, 15728640, array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic'])
on conflict (id) do update set public = false, file_size_limit = 15728640,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic'];

create table if not exists public.photo_albums (
  id         bigint generated always as identity primary key,
  name       text not null unique,
  created_at timestamptz not null default now()
);
alter table public.photo_albums enable row level security;

create table if not exists public.photos (
  id            bigint generated always as identity primary key,
  album_id      bigint not null references public.photo_albums(id) on delete cascade,
  path          text not null unique,
  caption       text,
  shared        boolean not null default false,
  uploaded_by   uuid references public.members(id) on delete set null,
  uploaded_name text,
  created_at    timestamptz not null default now()
);
alter table public.photos enable row level security;

-- Er biletet delt til framsida? (security definer, så anon kan sjekke utan å lese tabellen)
create or replace function public._photo_is_shared(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.photos where path = p_path and shared)
$$;
grant execute on function public._photo_is_shared(text) to anon, authenticated;

-- ---------- Storage-reglar ----------
drop policy if exists "bilete_les_medlem" on storage.objects;
drop policy if exists "bilete_les_open" on storage.objects;
drop policy if exists "bilete_last_opp" on storage.objects;
drop policy if exists "bilete_slett" on storage.objects;

create policy "bilete_les_medlem" on storage.objects for select to authenticated
  using (bucket_id = 'bilete' and public.is_member());
-- Alle (også utan innlogging) kan lese bilete som er delte til framsida
create policy "bilete_les_open" on storage.objects for select to anon, authenticated
  using (bucket_id = 'bilete' and public._photo_is_shared(name));
create policy "bilete_last_opp" on storage.objects for insert to authenticated
  with check (bucket_id = 'bilete' and public.is_member());
create policy "bilete_slett" on storage.objects for delete to authenticated
  using (bucket_id = 'bilete' and (owner = auth.uid() or public.has_access('nyheiter')));

-- ---------- Album ----------
create or replace function public.album_list()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return json_build_object('can_share', public.has_access('nyheiter'), 'albums', coalesce((select json_agg(json_build_object(
      'id', a.id, 'name', a.name,
      'count', (select count(*) from public.photos p where p.album_id = a.id),
      'shared', (select count(*) from public.photos p where p.album_id = a.id and p.shared),
      'cover', (select p.path from public.photos p where p.album_id = a.id order by p.shared desc, p.created_at desc limit 1))
      order by a.name) from public.photo_albums a), '[]'::json));
end $$;
grant execute on function public.album_list() to authenticated;

create or replace function public.album_create(p_name text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  p_name := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if length(p_name) < 2 or length(p_name) > 60 then raise exception 'bad_text'; end if;
  insert into public.photo_albums (name) values (p_name) on conflict (name) do nothing returning id into v_id;
  if v_id is null then select id into v_id from public.photo_albums where name = p_name; end if;
  return v_id;
end $$;
grant execute on function public.album_create(text) to authenticated;

-- ---------- Bilete ----------
create or replace function public.photo_list(p_album bigint)
returns json language plpgsql stable security definer set search_path = public as $$
declare v_kan boolean := public.has_access('nyheiter');
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return coalesce((select json_agg(json_build_object(
      'id', p.id, 'path', p.path, 'caption', p.caption, 'shared', p.shared,
      'uploaded_name', p.uploaded_name, 'created_at', p.created_at,
      'can_delete', p.uploaded_by = auth.uid() or v_kan) order by p.created_at desc, p.id desc)
    from public.photos p where p.album_id = p_album), '[]'::json);
end $$;
grant execute on function public.photo_list(bigint) to authenticated;

create or replace function public.photo_add(p_album bigint, p_path text, p_caption text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  if not exists (select 1 from public.photo_albums where id = p_album) then raise exception 'not_found'; end if;
  if p_path is null or p_path !~ ('^' || p_album || '/') then raise exception 'bad_path'; end if;
  insert into public.photos (album_id, path, caption, uploaded_by, uploaded_name)
  values (p_album, p_path, nullif(left(trim(coalesce(p_caption, '')), 200), ''), auth.uid(),
          (select name from public.members where id = auth.uid()))
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.photo_add(bigint, text, text) to authenticated;

create or replace function public.photo_set_shared(p_id bigint, p_shared boolean)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.has_access('nyheiter') then raise exception 'not_allowed'; end if;
  update public.photos set shared = coalesce(p_shared, false) where id = p_id;
end $$;
grant execute on function public.photo_set_shared(bigint, boolean) to authenticated;

-- Slettar raden og gir tilbake stien (sida slettar fila)
create or replace function public.photo_delete(p_id bigint)
returns text language plpgsql volatile security definer set search_path = public as $$
declare v_sti text;
begin
  delete from public.photos where id = p_id and (uploaded_by = auth.uid() or public.has_access('nyheiter'))
  returning path into v_sti;
  if v_sti is null then raise exception 'not_allowed'; end if;
  return v_sti;
end $$;
grant execute on function public.photo_delete(bigint) to authenticated;

-- ---------- Framsida (open) ----------
create or replace function public.photos_public()
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('path', p.path, 'caption', p.caption, 'album', a.name)
                  order by p.created_at desc, p.id desc), '[]'::json)
    from public.photos p join public.photo_albums a on a.id = p.album_id
   where p.shared
$$;
grant execute on function public.photos_public() to anon, authenticated;
