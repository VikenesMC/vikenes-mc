-- =====================================================================
-- Gjestebok på heimesida – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor (etter medlem.sql og nyheiter.sql).
-- Fila kan køyrast fleire gongar.
--
--  * Alle kan skrive ei helsing. Ho blir liggjande som «pending» (ventar).
--  * President, Vice President og Secretary godkjenner eller slettar frå
--    medlemssida. Berre godkjende helsingar blir viste på heimesida.
--  * Vern mot spam: lengdegrenser, felle-felt for robotar, maks 5
--    helsingar per minutt og maks 30 ventande i køen.
-- =====================================================================

create table if not exists public.guestbook (
  id           bigint generated always as identity primary key,
  name         text not null,
  message      text not null,
  status       text not null default 'pending',
  created_at   timestamptz not null default now(),
  approved_at  timestamptz,
  approved_by  uuid references public.members(id) on delete set null
);
alter table public.guestbook drop constraint if exists guestbook_status_check;
alter table public.guestbook add constraint guestbook_status_check
  check (status in ('pending', 'approved'));
alter table public.guestbook enable row level security;

-- Heimesida: dei 30 nyaste godkjende helsingane
create or replace function public.guestbook_public()
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'id', g.id, 'name', g.name, 'message', g.message, 'created_at', g.created_at)
           order by g.created_at desc), '[]'::json)
  from (select * from public.guestbook where status = 'approved'
        order by created_at desc limit 30) g
$$;
grant execute on function public.guestbook_public() to anon, authenticated;

-- Skrive ei helsing (alle). p_trap er eit usynleg felt: fyller ein robot det ut,
-- later vi som alt gjekk bra, men lagrar ingenting.
create or replace function public.guestbook_post(p_name text, p_message text, p_trap text default null)
returns text language plpgsql volatile security definer set search_path = public as $$
begin
  if coalesce(p_trap, '') <> '' then return 'ok'; end if;
  p_name := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  p_message := trim(coalesce(p_message, ''));
  if length(p_name) < 2 or length(p_name) > 60 then return 'bad_name'; end if;
  if length(p_message) < 2 or length(p_message) > 1000 then return 'bad_message'; end if;
  if (select count(*) from public.guestbook where created_at > now() - interval '1 minute') >= 5 then
    return 'busy';
  end if;
  if (select count(*) from public.guestbook where status = 'pending') >= 30 then
    return 'queue_full';
  end if;
  insert into public.guestbook (name, message) values (p_name, p_message);
  return 'ok';
end $$;
grant execute on function public.guestbook_post(text, text, text) to anon, authenticated;

-- Medlemssida (President, Vice President, Secretary): alle helsingar
create or replace function public.guestbook_all()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_news_writer() then raise exception 'not_allowed'; end if;
  return coalesce((select json_agg(json_build_object(
           'id', g.id, 'name', g.name, 'message', g.message,
           'status', g.status, 'created_at', g.created_at)
           order by (g.status = 'pending') desc, g.created_at desc)
         from public.guestbook g), '[]'::json);
end $$;
grant execute on function public.guestbook_all() to authenticated;

create or replace function public.guestbook_approve(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_news_writer() then raise exception 'not_allowed'; end if;
  update public.guestbook set status = 'approved', approved_at = now(), approved_by = auth.uid()
   where id = p_id;
end $$;
grant execute on function public.guestbook_approve(bigint) to authenticated;

create or replace function public.guestbook_delete(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_news_writer() then raise exception 'not_allowed'; end if;
  delete from public.guestbook where id = p_id;
end $$;
grant execute on function public.guestbook_delete(bigint) to authenticated;

-- Talet på ventande, så medlemssida kan vise eit varsel
create or replace function public.guestbook_pending_count()
returns int language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_news_writer() then return 0; end if;
  return (select count(*) from public.guestbook where status = 'pending');
end $$;
grant execute on function public.guestbook_pending_count() to authenticated;
