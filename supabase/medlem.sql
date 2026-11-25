-- =====================================================================
-- Medlemssida – Vikenes MC – steg 1: medlemsregister og roller
-- Køyr heile fila i Supabase → SQL Editor. Fila kan køyrast fleire gongar.
--
-- Slik verkar det:
--  * Medlemmen lagar konto (e-post + passord) på medlem.html og blir
--    «pending» (ventar).
--  * Berre President og Vice President kan godkjenne, gje roller og
--    fjerne medlemmer. Ingen kan endre seg sjølv (så ingen låser seg ute
--    ved ein feil).
--  * Tabellen kan ikkje lesast direkte frå nettsida (RLS utan policy) –
--    alt går gjennom funksjonane under, som sjekkar rolla.
-- =====================================================================

create table if not exists public.members (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null,
  phone       text,
  email       text,
  role        text not null default 'Member',
  status      text not null default 'pending',
  created_at  timestamptz not null default now(),
  approved_at timestamptz,
  approved_by uuid
);

alter table public.members drop constraint if exists members_status_check;
alter table public.members add constraint members_status_check
  check (status in ('pending', 'approved', 'removed'));

-- Rollene (engelsk, slik Kay vil ha det). Rekkjefølgja her er
-- rekkjefølgja i lista på sida.
create or replace function public.member_roles()
returns text[] language sql immutable as $$
  select array['President', 'Vice President', 'Secretary', 'Treasurer',
               'Sergeant at Arms', 'Road Captain', 'Board Member',
               'Member', 'Prospect', 'Hangaround']
$$;
grant execute on function public.member_roles() to anon, authenticated;

alter table public.members drop constraint if exists members_role_check;
alter table public.members add constraint members_role_check
  check (role = any (public.member_roles()));

alter table public.members enable row level security;
-- Ingen policy med vilje: berre funksjonane under slepp til.

-- ---------- Hjelpefunksjonar ----------
create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members
                 where id = auth.uid() and status = 'approved')
$$;
grant execute on function public.is_member() to authenticated;

create or replace function public._is_member_leader()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members
                 where id = auth.uid() and status = 'approved'
                   and role in ('President', 'Vice President'))
$$;
revoke all on function public._is_member_leader() from public, anon, authenticated;

-- ---------- Registrering (etter at kontoen er laga) ----------
create or replace function public.member_register(p_name text, p_phone text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  v_tlf text;
  v_rad public.members;
begin
  if auth.uid() is null then
    return json_build_object('status', 'not_logged_in');
  end if;

  p_name := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if length(p_name) < 2 or length(p_name) > 80 then
    return json_build_object('status', 'bad_name');
  end if;

  v_tlf := public._norm_tlf(p_phone);
  if v_tlf !~ '^[0-9]{8}$' then
    return json_build_object('status', 'bad_phone');
  end if;

  select * into v_rad from public.members where id = auth.uid();
  if found then
    -- Allereie registrert: berre ventande kan rette namn/telefon her
    if v_rad.status = 'pending' then
      update public.members set name = p_name, phone = v_tlf where id = auth.uid();
    end if;
    return json_build_object('status', v_rad.status);
  end if;

  if exists (select 1 from public.members where phone = v_tlf and status <> 'removed') then
    return json_build_object('status', 'phone_exists');
  end if;

  insert into public.members (id, name, phone, email)
  values (auth.uid(), p_name, v_tlf, auth.jwt() ->> 'email');
  return json_build_object('status', 'pending');
end $$;
grant execute on function public.member_register(text, text) to authenticated;

-- ---------- Meg sjølv ----------
create or replace function public.member_me()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', m.id, 'name', m.name, 'phone', m.phone, 'email', m.email,
    'role', m.role, 'status', m.status,
    'leader', (m.status = 'approved' and m.role in ('President', 'Vice President')),
    'news_writer', (m.status = 'approved' and m.role in ('President', 'Vice President', 'Secretary')))
  from public.members m where m.id = auth.uid()
$$;
grant execute on function public.member_me() to authenticated;

-- ---------- Medlemslista ----------
-- Godkjende medlemmer ser kvarandre (namn, rolle, telefon).
-- President/Vice President ser i tillegg ventande og fjerna, med e-post.
create or replace function public.member_list()
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_leiar boolean := public._is_member_leader();
begin
  if not public.is_member() then
    raise exception 'not_member';
  end if;
  return coalesce((
    select json_agg(json_build_object(
             'id', m.id, 'name', m.name, 'phone', m.phone, 'role', m.role,
             'status', m.status,
             'email', case when v_leiar then m.email end,
             'created_at', m.created_at)
           order by array_position(public.member_roles(), m.role), m.name)
    from public.members m
    where m.status = 'approved' or v_leiar
  ), '[]'::json);
end $$;
grant execute on function public.member_list() to authenticated;

-- ---------- Godkjenne / byte rolle / fjerne ----------
create or replace function public.member_set(p_id uuid, p_role text, p_status text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_member_leader() then
    raise exception 'not_allowed';
  end if;
  if p_id = auth.uid() then
    raise exception 'not_self';
  end if;
  if not (p_role = any (public.member_roles())) then
    raise exception 'bad_role';
  end if;
  if p_status not in ('pending', 'approved', 'removed') then
    raise exception 'bad_status';
  end if;

  update public.members
     set role = p_role,
         status = p_status,
         approved_at = case when p_status = 'approved' and status <> 'approved' then now() else approved_at end,
         approved_by = case when p_status = 'approved' and status <> 'approved' then auth.uid() else approved_by end
   where id = p_id;
  if not found then
    raise exception 'not_found';
  end if;
end $$;
grant execute on function public.member_set(uuid, text, text) to authenticated;
