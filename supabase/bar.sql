-- =====================================================================
-- Bar: varer med maks tal, lagerteljing og handleliste – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor ETTER klubbhus.sql.
-- Fila kan køyrast fleire gongar.
--
-- Kay 2026-11-26:
--  * Styret legg inn varer (øltypar, potetgull, brus …) med maks tal.
--  * Alle medlemmer kan telje lageret. «Må handlast» = maks − talt.
--  * ✔ Handla fyller vara opp til maks (lageret = maks).
--  * Same system for kjøkkenet (area = 'kjokken').
-- =====================================================================

create table if not exists public.bar_items (
  id              bigint generated always as identity primary key,
  name            text not null,
  category        text not null default 'Anna',
  max_qty         int  not null check (max_qty > 0),
  unit            text not null default 'stk',
  count_qty       int,                          -- sist talt (null = aldri talt)
  counted_at      timestamptz,
  counted_by_name text,
  created_at      timestamptz not null default now()
);
alter table public.bar_items enable row level security;
-- Kay 2026-11-26: kjøkkenet får same oppsett som baren → kolonna area ('bar' / 'kjokken')
alter table public.bar_items add column if not exists area text not null default 'bar';
alter table public.bar_items drop constraint if exists bar_items_area_check;
alter table public.bar_items add constraint bar_items_area_check check (area in ('bar', 'kjokken'));

create or replace function public._lager_kategoriar(p_area text)
returns text[] language sql immutable as $$
  select case when p_area = 'kjokken' then array['Kaffi og drikke', 'Mat', 'Forbruk', 'Anna']
              else array['Øl', 'Brus', 'Snacks', 'Anna'] end
$$;
alter table public.bar_items drop constraint if exists bar_items_category_check;
alter table public.bar_items add constraint bar_items_category_check check (category = any (public._lager_kategoriar(area)));

drop function if exists public.bar_list();
create or replace function public.bar_list(p_area text default 'bar')
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return json_build_object('can_edit', public._is_styre(auth.uid()), 'categories', public._lager_kategoriar(p_area),
    'items', coalesce((select json_agg(json_build_object(
      'id', b.id, 'name', b.name, 'category', b.category, 'max_qty', b.max_qty, 'unit', b.unit,
      'count_qty', b.count_qty, 'counted_at', b.counted_at, 'counted_by_name', b.counted_by_name,
      'need', case when b.count_qty is null then null else greatest(b.max_qty - b.count_qty, 0) end)
      order by array_position(public._lager_kategoriar(p_area), b.category), b.name)
    from public.bar_items b where b.area = p_area), '[]'::json));
end $$;
grant execute on function public.bar_list(text) to authenticated;

-- Styret: ny vare eller endre (p_id null = ny)
drop function if exists public.bar_item_save(bigint, text, text, int, text);
create or replace function public.bar_item_save(p_id bigint, p_name text, p_category text, p_max int, p_unit text, p_area text default 'bar')
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public._is_styre(auth.uid()) then raise exception 'not_allowed'; end if;
  if p_area not in ('bar', 'kjokken') then raise exception 'bad_area'; end if;
  p_name := trim(coalesce(p_name, '')); p_unit := coalesce(nullif(trim(coalesce(p_unit, '')), ''), 'stk');
  if length(p_name) < 2 or length(p_name) > 60 then raise exception 'bad_text'; end if;
  if p_max is null or p_max < 1 or p_max > 10000 then raise exception 'bad_max'; end if;
  if not (p_category = any (public._lager_kategoriar(p_area))) then raise exception 'bad_category'; end if;
  if p_id is null then
    insert into public.bar_items (name, category, max_qty, unit, area) values (p_name, p_category, p_max, left(p_unit, 20), p_area)
    returning id into v_id;
  else
    update public.bar_items set name = p_name, category = p_category, max_qty = p_max, unit = left(p_unit, 20)
     where id = p_id and area = p_area returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;
grant execute on function public.bar_item_save(bigint, text, text, int, text, text) to authenticated;

create or replace function public.bar_item_delete(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_styre(auth.uid()) then raise exception 'not_allowed'; end if;
  delete from public.bar_items where id = p_id;
end $$;
grant execute on function public.bar_item_delete(bigint) to authenticated;

-- Lagerteljing: p_counts = [{"id": 1, "count": 6}, …]. Tomme felt blir ikkje sende.
create or replace function public.bar_count(p_counts json)
returns void language plpgsql volatile security definer set search_path = public as $$
declare r record; v_namn text := (select name from public.members where id = auth.uid());
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  for r in select (x->>'id')::bigint as id, (x->>'count')::int as cnt from json_array_elements(p_counts) x loop
    if r.cnt is null or r.cnt < 0 or r.cnt > 100000 then raise exception 'bad_count'; end if;
    update public.bar_items set count_qty = r.cnt, counted_at = now(), counted_by_name = v_namn where id = r.id;
  end loop;
end $$;
grant execute on function public.bar_count(json) to authenticated;

-- ✔ Handla: lageret blir fylt opp til maks
create or replace function public.bar_bought(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  update public.bar_items set count_qty = max_qty, counted_at = now(),
         counted_by_name = (select name from public.members where id = auth.uid()) || ' (handla)'
   where id = p_id;
end $$;
grant execute on function public.bar_bought(bigint) to authenticated;
