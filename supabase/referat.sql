-- =====================================================================
-- Årsmøte: notatark som skjema + arkiverte referat – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor ETTER arsmote.sql.
-- Fila kan køyrast fleire gongar.
--
-- Kay 2026-11-26:
--  * Fana «Årsmøte»: meld inn sak til årsmøtet + notatarket («ÅRSMØTE –
--    NOTATARK») som skjema med dei 13 punkta.
--  * Utkast kan lagrast undervegs. «Arkiver» lagrar referatet, som så blir
--    vist rett i fana (som husreglane) – ikkje som dokument.
--  * Ved arkivering blir innmelde årsmøtesaker tekne med i referatet og
--    merkte som behandla.
--  * Fylle ut og arkivere: dei med arkiv-tilgang (President har alltid).
--    Alle medlemmer kan lese arkiverte referat.
-- =====================================================================

create table if not exists public.agm_minutes (
  id             bigint generated always as identity primary key,
  status         text not null default 'draft' check (status in ('draft', 'archived')),
  dato           date,
  place          text,
  leader         text,
  referent       text,
  points         jsonb not null default '[]'::jsonb,   -- 13 tekstar, punkt 1–13
  cases          jsonb not null default '[]'::jsonb,   -- innkomne saker (kopi ved arkivering)
  sign_leader    text,
  sign_leader_dato   date,
  sign_referent  text,
  sign_referent_dato date,
  updated_by_name text,
  updated_at     timestamptz not null default now(),
  archived_at    timestamptz
);
alter table public.agm_minutes enable row level security;

create or replace function public._minutes_json(m public.agm_minutes)
returns json language sql stable as $$
  select json_build_object('id', m.id, 'status', m.status, 'dato', m.dato, 'place', m.place,
    'leader', m.leader, 'referent', m.referent, 'points', m.points, 'cases', m.cases,
    'sign_leader', m.sign_leader, 'sign_leader_dato', m.sign_leader_dato,
    'sign_referent', m.sign_referent, 'sign_referent_dato', m.sign_referent_dato,
    'updated_by_name', m.updated_by_name, 'updated_at', m.updated_at, 'archived_at', m.archived_at)
$$;

-- Alt fana treng: utkast (berre for dei som kan skrive) + arkiverte referat (alle)
create or replace function public.minutes_overview()
returns json language plpgsql stable security definer set search_path = public as $$
declare v_kan boolean := public.has_access('arkiv');
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return json_build_object(
    'can_edit', v_kan,
    'draft', case when v_kan then (select public._minutes_json(m) from public.agm_minutes m where m.status = 'draft' order by m.id desc limit 1) end,
    'archived', coalesce((select json_agg(public._minutes_json(m) order by m.dato desc nulls last, m.id desc)
                          from public.agm_minutes m where m.status = 'archived'), '[]'::json));
end $$;
grant execute on function public.minutes_overview() to authenticated;

-- Lagre utkastet (lagar det om det ikkje finst). p_data har same felt som _minutes_json.
create or replace function public.minutes_save(p_data json)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.has_access('arkiv') then raise exception 'not_allowed'; end if;
  select id into v_id from public.agm_minutes where status = 'draft' order by id desc limit 1;
  if v_id is null then
    insert into public.agm_minutes (status) values ('draft') returning id into v_id;
  end if;
  update public.agm_minutes set
    dato = nullif(p_data->>'dato', '')::date,
    place = left(nullif(trim(coalesce(p_data->>'place', '')), ''), 120),
    leader = left(nullif(trim(coalesce(p_data->>'leader', '')), ''), 80),
    referent = left(nullif(trim(coalesce(p_data->>'referent', '')), ''), 80),
    points = coalesce((p_data->'points')::jsonb, '[]'::jsonb),
    sign_leader = left(nullif(trim(coalesce(p_data->>'sign_leader', '')), ''), 80),
    sign_leader_dato = nullif(p_data->>'sign_leader_dato', '')::date,
    sign_referent = left(nullif(trim(coalesce(p_data->>'sign_referent', '')), ''), 80),
    sign_referent_dato = nullif(p_data->>'sign_referent_dato', '')::date,
    updated_by_name = (select name from public.members where id = auth.uid()),
    updated_at = now()
  where id = v_id;
  return v_id;
end $$;
grant execute on function public.minutes_save(json) to authenticated;

-- Arkiver utkastet: lagrar, tek med innmelde årsmøtesaker og merkjer dei behandla
create or replace function public.minutes_archive(p_data json)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint;
begin
  v_id := public.minutes_save(p_data);
  if (select dato from public.agm_minutes where id = v_id) is null then raise exception 'no_date'; end if;
  update public.agm_minutes set
    cases = coalesce((select jsonb_agg(jsonb_build_object('body', c.body,
               'from', case when c.anonymous then 'Anonym' else coalesce(c.author_name, '–') end,
               'dato', c.created_at::date) order by c.created_at)
             from public.agm_cases c where c.target = 'arsmote' and not c.hidden and not c.handled), '[]'::jsonb),
    status = 'archived', archived_at = now()
  where id = v_id;
  update public.agm_cases set handled = true where target = 'arsmote' and not hidden and not handled;
  return v_id;
end $$;
grant execute on function public.minutes_archive(json) to authenticated;
