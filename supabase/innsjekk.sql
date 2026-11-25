-- =====================================================================
-- Innsjekking i gjesteboka – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor (etter gjestebok.sql).
-- Fila kan køyrast fleire gongar.
--
--  * Gjestar vel klubben sin og kan sjekke inn og/eller skrive ei helsing.
--  * Innsjekkingar tel med ein gong (Kay sitt val) – pokal med tal på
--    klubbkortet på framsida. Grense: 20 innsjekkingar i minuttet totalt.
--  * Klubb som ikkje står på lista → «ukjend klubb» som styret ser på
--    medlemssida og kan merke som ordna når klubben er lagd til.
-- =====================================================================

alter table public.guestbook add column if not exists club_name text;

create table if not exists public.checkins (
  id          bigint generated always as identity primary key,
  club_slug   text,               -- null = klubb som ikkje står på lista
  club_name   text not null,
  name        text,
  handled     boolean not null default false,
  created_at  timestamptz not null default now()
);
alter table public.checkins enable row level security;

-- Sende inn frå gjesteboka: innsjekk og/eller helsing
create or replace function public.guest_submit(p_name text, p_message text, p_club_slug text,
                                               p_club_name text, p_checkin boolean, p_trap text default null)
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  v_skriv boolean;
begin
  if coalesce(p_trap, '') <> '' then return 'ok'; end if;
  p_name := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  p_message := trim(coalesce(p_message, ''));
  p_club_name := nullif(regexp_replace(trim(coalesce(p_club_name, '')), '\s+', ' ', 'g'), '');
  p_club_slug := nullif(trim(coalesce(p_club_slug, '')), '');
  v_skriv := p_message <> '';

  if length(p_name) < 2 or length(p_name) > 60 then return 'bad_name'; end if;
  if not coalesce(p_checkin, false) and not v_skriv then return 'nothing'; end if;
  if v_skriv and (length(p_message) < 2 or length(p_message) > 1000) then return 'bad_message'; end if;
  if p_club_slug is not null and p_club_slug !~ '^[a-z0-9-]{2,60}$' then return 'bad_club'; end if;
  if p_club_name is not null and length(p_club_name) > 80 then return 'bad_club'; end if;
  if coalesce(p_checkin, false) and p_club_name is null then return 'need_club'; end if;

  if coalesce(p_checkin, false) then
    if (select count(*) from public.checkins where created_at > now() - interval '1 minute') >= 20 then
      return 'busy';
    end if;
    insert into public.checkins (club_slug, club_name, name) values (p_club_slug, p_club_name, p_name);
  end if;

  if v_skriv then
    if (select count(*) from public.guestbook where created_at > now() - interval '1 minute') >= 5 then
      return case when coalesce(p_checkin, false) then 'ok_checkin_busy' else 'busy' end;
    end if;
    if (select count(*) from public.guestbook where status = 'pending') >= 30 then
      return case when coalesce(p_checkin, false) then 'ok_checkin_busy' else 'queue_full' end;
    end if;
    insert into public.guestbook (name, message, club_name) values (p_name, p_message, p_club_name);
  end if;
  return 'ok';
end $$;
grant execute on function public.guest_submit(text, text, text, text, boolean, text) to anon, authenticated;

-- Tal innsjekkingar per klubb (for pokalen på framsida)
create or replace function public.checkin_counts()
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_object_agg(club_slug, n), '{}'::json)
  from (select club_slug, count(*) as n from public.checkins
         where club_slug is not null group by club_slug) x
$$;
grant execute on function public.checkin_counts() to anon, authenticated;

-- Helsingane får med klubben
create or replace function public.guestbook_public()
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'id', g.id, 'name', g.name, 'message', g.message, 'club_name', g.club_name,
           'created_at', g.created_at) order by g.created_at desc), '[]'::json)
  from (select * from public.guestbook where status = 'approved'
        order by created_at desc limit 30) g
$$;
grant execute on function public.guestbook_public() to anon, authenticated;

create or replace function public.guestbook_all()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_news_writer() then raise exception 'not_allowed'; end if;
  return coalesce((select json_agg(json_build_object(
           'id', g.id, 'name', g.name, 'message', g.message, 'club_name', g.club_name,
           'status', g.status, 'created_at', g.created_at)
           order by (g.status = 'pending') desc, g.created_at desc)
         from public.guestbook g), '[]'::json);
end $$;
grant execute on function public.guestbook_all() to authenticated;

-- Ukjende klubbar (ikkje på lista) som styret bør leggje til
create or replace function public.unknown_clubs()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_news_writer() then raise exception 'not_allowed'; end if;
  return coalesce((select json_agg(json_build_object(
           'club_name', x.club_name, 'count', x.n, 'last', x.siste) order by x.siste desc)
         from (select club_name, count(*) as n, max(created_at) as siste
                 from public.checkins where club_slug is null and not handled
                group by club_name) x), '[]'::json);
end $$;
grant execute on function public.unknown_clubs() to authenticated;

create or replace function public.unknown_club_handled(p_club_name text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_news_writer() then raise exception 'not_allowed'; end if;
  update public.checkins set handled = true where club_slug is null and club_name = p_club_name;
end $$;
grant execute on function public.unknown_club_handled(text) to authenticated;

-- Talet på fana «Gjestebok»: ventande helsingar + ukjende klubbar
create or replace function public.guestbook_pending_count()
returns int language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_news_writer() then return 0; end if;
  return (select count(*) from public.guestbook where status = 'pending')
       + (select count(distinct club_name) from public.checkins where club_slug is null and not handled);
end $$;
grant execute on function public.guestbook_pending_count() to authenticated;
