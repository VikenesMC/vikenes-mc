-- =====================================================================
-- Tilgangsregister – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor (etter alle dei andre filene).
--
-- President styrer kven som slepp inn kvar. President har alltid alt.
-- Område:
--   quiz_admin       – Quiz-admin og QR-utskrift
--   medlemsregister  – godkjenne medlemmer og gje roller
--   nyheiter         – skrive nyheiter og godkjenne gjesteboka
--   arkiv            – laste opp og slette dokument i arkivet
--   regnskap         – regnskapet og regnskapsmappa
--
-- Første køyring fyller registeret slik rollene var, og gir ALLE godkjende
-- medlemmer quiz_admin (Kay 2026-11-25: alle skal kunne sjå og gje
-- tilbakemelding). Seinare køyringar endrar ikkje det President har sett.
-- =====================================================================

create table if not exists public.member_access (
  member_id  uuid not null references public.members(id) on delete cascade,
  area       text not null,
  primary key (member_id, area)
);
alter table public.member_access enable row level security;

create or replace function public.access_areas()
returns text[] language sql immutable as $$
  select array['quiz_admin', 'medlemsregister', 'nyheiter', 'arkiv', 'regnskap']
$$;
grant execute on function public.access_areas() to authenticated;

-- Fyll registeret første gong (berre om det er tomt)
do $$
begin
  if not exists (select 1 from public.member_access) then
    insert into public.member_access (member_id, area)
    select m.id, a.area from public.members m
    cross join lateral (values
      ('quiz_admin', true),
      ('medlemsregister', m.role in ('President', 'Vice President')),
      ('nyheiter', m.role in ('President', 'Vice President', 'Secretary')),
      ('arkiv', m.role in ('President', 'Vice President')),
      ('regnskap', m.role in ('President', 'Treasurer'))
    ) as a(area, ja)
    where m.status = 'approved' and a.ja;
  end if;
end $$;

-- Har den innlogga tilgang til eit område?
create or replace function public.has_access(p_area text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.members m
    where m.id = auth.uid() and m.status = 'approved'
      and (m.role = 'President'
           or exists (select 1 from public.member_access x where x.member_id = m.id and x.area = p_area))
  )
$$;
grant execute on function public.has_access(text) to authenticated;

-- ---------- Alle sperrer bruker no registeret ----------
create or replace function public._is_member_leader()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_access('medlemsregister')
$$;

create or replace function public._is_news_writer()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_access('nyheiter')
$$;

create or replace function public._can_regnskap()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_access('regnskap')
$$;

create or replace function public.can_see_folder(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_folder = any (public.arkiv_mapper())
     and public.is_member()
     and (p_folder <> 'regnskap' or public.has_access('regnskap'))
$$;

create or replace function public.can_write_folder(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_folder = any (public.arkiv_mapper())
     and case when p_folder = 'regnskap' then public.has_access('regnskap') else public.has_access('arkiv') end
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.admins a
    where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  ) or public.has_access('quiz_admin')
$$;

create or replace function public.member_me()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', m.id, 'name', m.name, 'phone', m.phone, 'email', m.email,
    'role', m.role, 'status', m.status,
    'leader', public.has_access('medlemsregister'),
    'news_writer', public.has_access('nyheiter'),
    'arkiv', public.has_access('arkiv'),
    'regnskap', public.has_access('regnskap'),
    'quiz_admin', public.has_access('quiz_admin'))
  from public.members m where m.id = auth.uid()
$$;
grant execute on function public.member_me() to authenticated;

-- ---------- President styrer registeret ----------
create or replace function public.access_list()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.members where id = auth.uid() and status = 'approved' and role = 'President') then
    raise exception 'not_allowed';
  end if;
  return coalesce((select json_agg(json_build_object(
           'id', m.id, 'name', m.name, 'role', m.role,
           'areas', coalesce((select json_agg(x.area) from public.member_access x where x.member_id = m.id), '[]'::json))
           order by array_position(public.member_roles(), m.role), m.name)
         from public.members m where m.status = 'approved'), '[]'::json);
end $$;
grant execute on function public.access_list() to authenticated;

create or replace function public.access_set(p_member uuid, p_area text, p_allowed boolean)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not exists (select 1 from public.members where id = auth.uid() and status = 'approved' and role = 'President') then
    raise exception 'not_allowed';
  end if;
  if not (p_area = any (public.access_areas())) then raise exception 'bad_area'; end if;
  if p_allowed then
    insert into public.member_access (member_id, area) values (p_member, p_area) on conflict do nothing;
  else
    delete from public.member_access where member_id = p_member and area = p_area;
  end if;
end $$;
grant execute on function public.access_set(uuid, text, boolean) to authenticated;
