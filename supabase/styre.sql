-- =====================================================================
-- Styregodkjenning av endringar i medlemsregisteret – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor ETTER tilgang.sql.
-- Fila kan køyrast fleire gongar.
--
-- Bestemt av Kay 2026-11-25:
--  * Styret = President, Vice President, Treasurer, Board Member.
--  * Byte tittel eller slette ein godkjend medlem blir eit FORSLAG.
--    Alle i styret får varsel og må godkjenne før det trer i kraft.
--    Den som foreslår, tel som ja. Éin nei stoppar forslaget.
--  * Den forslaget gjeld, røystar ikkje sjølv.
--  * Er det ingen andre i styret, gjeld endringa med ein gong.
--  * Nye medlemmer blir godkjende som før (utan styret).
--  * «Slette» = status removed (personen mister tilgangen, kan hentast att).
-- =====================================================================

create or replace function public.styre_roles()
returns text[] language sql immutable as $$
  select array['President', 'Vice President', 'Treasurer', 'Board Member']
$$;
grant execute on function public.styre_roles() to authenticated;

create table if not exists public.member_changes (
  id            bigint generated always as identity primary key,
  member_id     uuid not null references public.members(id) on delete cascade,
  kind          text not null check (kind in ('role', 'remove')),
  new_role      text,
  proposed_by   uuid references public.members(id) on delete set null,
  proposed_name text,
  status        text not null default 'open' check (status in ('open', 'applied', 'rejected', 'cancelled')),
  created_at    timestamptz not null default now(),
  decided_at    timestamptz
);
alter table public.member_changes enable row level security;

create table if not exists public.member_change_votes (
  change_id  bigint not null references public.member_changes(id) on delete cascade,
  voter_id   uuid not null references public.members(id) on delete cascade,
  yes        boolean not null,
  voted_at   timestamptz not null default now(),
  primary key (change_id, voter_id)
);
alter table public.member_change_votes enable row level security;

create or replace function public._is_styre(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members
                  where id = p_id and status = 'approved' and role = any (public.styre_roles()))
$$;
revoke all on function public._is_styre(uuid) from public, anon, authenticated;

-- Kven må godkjenne eit forslag: styret slik det er no, utan den det gjeld
create or replace function public._change_voters(p_change bigint)
returns table (id uuid) language sql stable security definer set search_path = public as $$
  select m.id from public.members m, public.member_changes c
   where c.id = p_change and m.status = 'approved'
     and m.role = any (public.styre_roles()) and m.id <> c.member_id
$$;
revoke all on function public._change_voters(bigint) from public, anon, authenticated;

-- Sjekk om forslaget er avgjort, og gjennomfør det om alle har sagt ja
create or replace function public._change_try_apply(p_change bigint)
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  c public.member_changes;
begin
  select * into c from public.member_changes where id = p_change for update;
  if not found then raise exception 'not_found'; end if;
  if c.status <> 'open' then return c.status; end if;

  if exists (select 1 from public.member_change_votes v
              where v.change_id = p_change and not v.yes
                and v.voter_id in (select id from public._change_voters(p_change))) then
    update public.member_changes set status = 'rejected', decided_at = now() where id = p_change;
    return 'rejected';
  end if;

  if exists (select 1 from public._change_voters(p_change) x
              where not exists (select 1 from public.member_change_votes v
                                 where v.change_id = p_change and v.voter_id = x.id and v.yes)) then
    return 'open';
  end if;

  if c.kind = 'role' then
    update public.members set role = c.new_role where id = c.member_id and status = 'approved';
  else
    update public.members set status = 'removed' where id = c.member_id;
  end if;
  update public.member_changes set status = 'applied', decided_at = now() where id = p_change;
  return 'applied';
end $$;
revoke all on function public._change_try_apply(bigint) from public, anon, authenticated;

-- Nytt forslag: byte tittel ('role' + ny tittel) eller slette ('remove')
create or replace function public.member_change_propose(p_member uuid, p_kind text, p_role text default null)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  v_mal public.members;
  v_id bigint;
  v_status text;
begin
  if not public.has_access('medlemsregister') then raise exception 'not_allowed'; end if;
  if p_member = auth.uid() then raise exception 'not_self'; end if;
  select * into v_mal from public.members where id = p_member and status = 'approved';
  if not found then raise exception 'not_found'; end if;
  if p_kind not in ('role', 'remove') then raise exception 'bad_kind'; end if;
  if p_kind = 'role' then
    if not (p_role = any (public.member_roles())) then raise exception 'bad_role'; end if;
    if p_role = v_mal.role then raise exception 'same_role'; end if;
  else
    p_role := null;
  end if;

  -- Eit nytt forslag for same person erstattar det gamle
  update public.member_changes set status = 'cancelled', decided_at = now()
   where member_id = p_member and status = 'open';

  insert into public.member_changes (member_id, kind, new_role, proposed_by, proposed_name)
  values (p_member, p_kind, p_role, auth.uid(), (select name from public.members where id = auth.uid()))
  returning id into v_id;

  if public._is_styre(auth.uid()) then
    insert into public.member_change_votes (change_id, voter_id, yes) values (v_id, auth.uid(), true);
  end if;

  v_status := public._change_try_apply(v_id);
  return json_build_object('id', v_id, 'status', v_status);
end $$;
grant execute on function public.member_change_propose(uuid, text, text) to authenticated;

-- Styremedlem seier ja eller nei
create or replace function public.member_change_vote(p_change bigint, p_yes boolean)
returns text language plpgsql volatile security definer set search_path = public as $$
begin
  if not exists (select 1 from public._change_voters(p_change) where id = auth.uid()) then
    raise exception 'not_allowed';
  end if;
  if not exists (select 1 from public.member_changes where id = p_change and status = 'open') then
    raise exception 'closed';
  end if;
  insert into public.member_change_votes (change_id, voter_id, yes) values (p_change, auth.uid(), p_yes)
  on conflict (change_id, voter_id) do update set yes = excluded.yes, voted_at = now();
  return public._change_try_apply(p_change);
end $$;
grant execute on function public.member_change_vote(bigint, boolean) to authenticated;

-- Trekkje forslaget (den som foreslo, eller President)
create or replace function public.member_change_cancel(p_change bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  update public.member_changes set status = 'cancelled', decided_at = now()
   where id = p_change and status = 'open'
     and (proposed_by = auth.uid()
          or exists (select 1 from public.members where id = auth.uid() and status = 'approved' and role = 'President'));
  if not found then raise exception 'not_allowed'; end if;
end $$;
grant execute on function public.member_change_cancel(bigint) to authenticated;

-- Opne forslag med kven som har svart (for styret og medlemsregisteret)
create or replace function public.member_changes_open()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not (public._is_styre(auth.uid()) or public.has_access('medlemsregister')) then
    return '[]'::json;
  end if;
  return coalesce((select json_agg(json_build_object(
      'id', c.id, 'member_id', c.member_id, 'member_name', m.name, 'member_role', m.role,
      'kind', c.kind, 'new_role', c.new_role, 'proposed_name', c.proposed_name, 'created_at', c.created_at,
      'can_vote', exists (select 1 from public._change_voters(c.id) x where x.id = auth.uid()),
      'my_vote', (select v.yes from public.member_change_votes v where v.change_id = c.id and v.voter_id = auth.uid()),
      'can_cancel', (c.proposed_by = auth.uid() or exists (select 1 from public.members
                       where id = auth.uid() and status = 'approved' and role = 'President')),
      'voters', (select coalesce(json_agg(json_build_object('name', s.name, 'yes', v.yes) order by s.name), '[]'::json)
                   from public._change_voters(c.id) x
                   join public.members s on s.id = x.id
                   left join public.member_change_votes v on v.change_id = c.id and v.voter_id = x.id))
      order by c.created_at)
    from public.member_changes c join public.members m on m.id = c.member_id
    where c.status = 'open'), '[]'::json);
end $$;
grant execute on function public.member_changes_open() to authenticated;

-- ---------- Godkjende medlemmer kan ikkje lenger endrast direkte ----------
-- member_set gjeld no berre ventande (godkjenne/avvise) og fjerna (gje tilgang att).
create or replace function public.member_set(p_id uuid, p_role text, p_status text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_member_leader() then raise exception 'not_allowed'; end if;
  if p_id = auth.uid() then raise exception 'not_self'; end if;
  if not (p_role = any (public.member_roles())) then raise exception 'bad_role'; end if;
  if p_status not in ('pending', 'approved', 'removed') then raise exception 'bad_status'; end if;
  if exists (select 1 from public.members where id = p_id and status = 'approved') then
    raise exception 'needs_styre';
  end if;

  update public.members
     set role = p_role,
         status = p_status,
         approved_at = case when p_status = 'approved' and status <> 'approved' then now() else approved_at end,
         approved_by = case when p_status = 'approved' and status <> 'approved' then auth.uid() else approved_by end
   where id = p_id;
  if not found then raise exception 'not_found'; end if;
end $$;
grant execute on function public.member_set(uuid, text, text) to authenticated;

-- Medlemslista viser om det ligg eit forslag til styret på personen
create or replace function public.member_list()
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_leiar boolean := public._is_member_leader();
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return coalesce((
    select json_agg(json_build_object(
             'id', m.id, 'name', m.name, 'phone', m.phone, 'role', m.role,
             'status', m.status,
             'email', case when v_leiar then m.email end,
             'created_at', m.created_at,
             'change', (select json_build_object('kind', c.kind, 'new_role', c.new_role)
                          from public.member_changes c where c.member_id = m.id and c.status = 'open'
                          order by c.created_at desc limit 1))
           order by array_position(public.member_roles(), m.role), m.name)
    from public.members m
    where m.status = 'approved' or v_leiar
  ), '[]'::json);
end $$;
grant execute on function public.member_list() to authenticated;

-- member_me får 'styre' (sjå tilgang.sql for resten)
create or replace function public.member_me()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', m.id, 'name', m.name, 'phone', m.phone, 'email', m.email,
    'role', m.role, 'status', m.status,
    'leader', public.has_access('medlemsregister'),
    'news_writer', public.has_access('nyheiter'),
    'arkiv', public.has_access('arkiv'),
    'regnskap', public.has_access('regnskap'),
    'quiz_admin', public.has_access('quiz_admin'),
    'styre', public._is_styre(m.id))
  from public.members m where m.id = auth.uid()
$$;
grant execute on function public.member_me() to authenticated;
