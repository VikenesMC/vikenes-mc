-- =====================================================================
-- Klubbhuset: handleliste, lånebok og vinterlagring – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor ETTER arsmote.sql.
-- Fila kan køyrast fleire gongar.
--
-- Kay 2026-11-26: fana «Klubbhuset» samlar husreglane og skjema:
--  * Kjøkken: handleliste alle ser. Den som handlar, fjernar varen.
--  * Verkstad: lånebok (husregel 1.3) – kven har lånt kva heim.
--  * Lagring: meld inn MC til vinterlagring (husregel 5), med forsikring.
--  * Feil/skade på verkstad- og bryggeutstyr blir sendt som hastesak til
--    styret (agm_cases, target 'styret') – sjå arsmote.sql.
-- =====================================================================

-- ---------- Handleliste (kjøkken) ----------
create table if not exists public.shopping_items (
  id         bigint generated always as identity primary key,
  item       text not null,
  added_by   uuid references public.members(id) on delete set null,
  added_name text,
  created_at timestamptz not null default now()
);
alter table public.shopping_items enable row level security;

create or replace function public.shop_list()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return coalesce((select json_agg(json_build_object('id', s.id, 'item', s.item, 'added_name', s.added_name,
           'created_at', s.created_at) order by s.created_at) from public.shopping_items s), '[]'::json);
end $$;
grant execute on function public.shop_list() to authenticated;

create or replace function public.shop_add(p_item text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  p_item := trim(coalesce(p_item, ''));
  if length(p_item) < 1 or length(p_item) > 120 then raise exception 'bad_text'; end if;
  insert into public.shopping_items (item, added_by, added_name)
  values (p_item, auth.uid(), (select name from public.members where id = auth.uid())) returning id into v_id;
  return v_id;
end $$;
grant execute on function public.shop_add(text) to authenticated;

-- Handla → varen forsvinn frå lista (alle medlemmer kan)
create or replace function public.shop_done(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  delete from public.shopping_items where id = p_id;
end $$;
grant execute on function public.shop_done(bigint) to authenticated;

-- ---------- Lånebok (verktøy/utstyr lånt med heim) ----------
create table if not exists public.tool_loans (
  id          bigint generated always as identity primary key,
  item        text not null,
  member_id   uuid references public.members(id) on delete set null,
  member_name text,
  lent_at     timestamptz not null default now(),
  returned_at timestamptz
);
alter table public.tool_loans enable row level security;

create or replace function public.loan_list()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return coalesce((select json_agg(json_build_object('id', l.id, 'item', l.item, 'member_name', l.member_name,
           'lent_at', l.lent_at, 'mine', l.member_id = auth.uid()) order by l.lent_at)
         from public.tool_loans l where l.returned_at is null), '[]'::json);
end $$;
grant execute on function public.loan_list() to authenticated;

create or replace function public.loan_add(p_item text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  p_item := trim(coalesce(p_item, ''));
  if length(p_item) < 2 or length(p_item) > 150 then raise exception 'bad_text'; end if;
  insert into public.tool_loans (item, member_id, member_name)
  values (p_item, auth.uid(), (select name from public.members where id = auth.uid())) returning id into v_id;
  return v_id;
end $$;
grant execute on function public.loan_add(text) to authenticated;

-- Levert tilbake: den som lånte, eller styret
create or replace function public.loan_return(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  update public.tool_loans set returned_at = now()
   where id = p_id and returned_at is null
     and (member_id = auth.uid() or public._is_styre(auth.uid()));
  if not found then raise exception 'not_allowed'; end if;
end $$;
grant execute on function public.loan_return(bigint) to authenticated;

-- ---------- Vinterlagring ----------
create table if not exists public.storage_bikes (
  id          bigint generated always as identity primary key,
  season      text not null,                 -- t.d. '2026/2027'
  member_id   uuid references public.members(id) on delete cascade,
  member_name text,
  bike        text not null,                 -- merke/modell
  reg_nr      text,
  owner_note  text,                          -- eigen / familie (5.1)
  insured     boolean not null,              -- lagringsforsikring inkl. brann (5.2)
  created_at  timestamptz not null default now()
);
alter table public.storage_bikes enable row level security;

-- Sesongen startar om hausten: frå juli reknar me neste vinter
create or replace function public._lagringssesong()
returns text language sql stable as $$
  select case when extract(month from current_date) >= 7
              then extract(year from current_date)::int || '/' || (extract(year from current_date)::int + 1)
              else (extract(year from current_date)::int - 1) || '/' || extract(year from current_date)::int end
$$;

-- Pris og betaling (Kay 2026-11-26)
--   Fullt medlem: 2 syklar gratis
--   Prospect:     1 gratis + 1 til 1000 kr
--   Hangaround:   1 sykkel til 1000 kr
--   Utanfor klubben (5.3, styret godkjenner): 1800 kr per sykkel – blir lagt inn av regnskap/President
--   «Betalt» blir merkt av dei med regnskapstilgang (og President).
alter table public.storage_bikes add column if not exists price        int     not null default 0;
alter table public.storage_bikes add column if not exists paid         boolean not null default false;
alter table public.storage_bikes add column if not exists paid_at      timestamptz;
alter table public.storage_bikes add column if not exists paid_by_name text;
alter table public.storage_bikes add column if not exists guest_name   text;   -- ikkje-medlem
alter table public.storage_bikes add column if not exists registered_by uuid references public.members(id) on delete set null;

-- Pris for sykkel nr. p_nr (1, 2 …) for ei rolle. null = ikkje lov (over maks).
create or replace function public._lagringspris(p_role text, p_nr int)
returns int language sql immutable as $$
  select case
    when p_role = 'Hangaround' then case when p_nr = 1 then 1000 end
    when p_role = 'Prospect'   then case when p_nr = 1 then 0 when p_nr = 2 then 1000 end
    else                            case when p_nr <= 2 then 0 end
  end
$$;

-- Rekn om prisen på ubetalte syklar til eit medlem (t.d. etter at ein er fjerna)
create or replace function public._lagring_prisar(p_member uuid, p_sesong text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare v_rolle text := (select role from public.members where id = p_member); r record; n int := 0;
begin
  for r in select id, paid from public.storage_bikes where member_id = p_member and season = p_sesong order by created_at, id loop
    n := n + 1;
    if not r.paid then
      update public.storage_bikes set price = coalesce(public._lagringspris(v_rolle, n), 0) where id = r.id;
    end if;
  end loop;
end $$;
revoke all on function public._lagring_prisar(uuid, text) from public, anon, authenticated;

create or replace function public.storage_list()
returns json language plpgsql stable security definer set search_path = public as $$
declare v_sesong text := public._lagringssesong(); v_regn boolean := public.has_access('regnskap');
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return json_build_object('season', v_sesong, 'can_pay', v_regn,
    'total', (select coalesce(sum(price), 0) from public.storage_bikes where season = v_sesong),
    'paid_total', (select coalesce(sum(price), 0) from public.storage_bikes where season = v_sesong and paid),
    'bikes', coalesce((select json_agg(json_build_object(
      'id', b.id, 'member_name', coalesce(b.guest_name, b.member_name), 'guest', b.guest_name is not null,
      'bike', b.bike, 'reg_nr', b.reg_nr, 'owner_note', b.owner_note, 'insured', b.insured,
      'price', b.price, 'paid', b.paid, 'paid_at', b.paid_at, 'paid_by_name', b.paid_by_name,
      'mine', b.member_id = auth.uid()) order by (b.guest_name is not null), coalesce(b.guest_name, b.member_name), b.created_at)
    from public.storage_bikes b where b.season = v_sesong), '[]'::json));
end $$;
grant execute on function public.storage_list() to authenticated;

-- Medlem melder inn eigen sykkel. Maks og pris etter rolla.
create or replace function public.storage_add(p_bike text, p_reg_nr text, p_owner_note text, p_insured boolean)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint; v_sesong text := public._lagringssesong();
  v_rolle text := (select role from public.members where id = auth.uid()); v_nr int; v_pris int;
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  if not coalesce(p_insured, false) then raise exception 'not_insured'; end if;
  p_bike := trim(coalesce(p_bike, ''));
  if length(p_bike) < 2 or length(p_bike) > 100 then raise exception 'bad_text'; end if;
  v_nr := (select count(*) from public.storage_bikes where member_id = auth.uid() and season = v_sesong) + 1;
  v_pris := public._lagringspris(v_rolle, v_nr);
  if v_pris is null then raise exception 'max_bikes'; end if;
  insert into public.storage_bikes (season, member_id, member_name, bike, reg_nr, owner_note, insured, price, registered_by)
  values (v_sesong, auth.uid(), (select name from public.members where id = auth.uid()), p_bike,
          nullif(upper(trim(coalesce(p_reg_nr, ''))), ''), nullif(left(trim(coalesce(p_owner_note, '')), 100), ''), true,
          v_pris, auth.uid())
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.storage_add(text, text, text, boolean) to authenticated;

-- Kay 2026-11-26: Berre dei som betaler blir skrivne inn, og det gjer kasserar/President.
-- p_kind: 'ute' (utanfor klubben, 1800), 'hangaround' (1000), 'prospect2' (Prospect sykkel nr. 2, 1000)
drop function if exists public.storage_add_guest(text, text, text, boolean);
create or replace function public.storage_add_guest(p_name text, p_bike text, p_reg_nr text, p_insured boolean, p_kind text default 'ute')
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint; v_pris int; v_type text;
begin
  if not public.has_access('regnskap') then raise exception 'not_allowed'; end if;
  if not coalesce(p_insured, false) then raise exception 'not_insured'; end if;
  p_name := trim(coalesce(p_name, '')); p_bike := trim(coalesce(p_bike, ''));
  if length(p_name) < 2 or length(p_name) > 80 or length(p_bike) < 2 or length(p_bike) > 100 then raise exception 'bad_text'; end if;
  select x.pris, x.typ into v_pris, v_type from (values
    ('ute', 1800, 'Utanfor klubben'), ('hangaround', 1000, 'Hangaround'), ('prospect2', 1000, 'Prospect, sykkel nr. 2')
  ) as x(kind, pris, typ) where x.kind = p_kind;
  if v_pris is null then raise exception 'bad_kind'; end if;
  insert into public.storage_bikes (season, guest_name, bike, reg_nr, owner_note, insured, price, registered_by)
  values (public._lagringssesong(), p_name, p_bike, nullif(upper(trim(coalesce(p_reg_nr, ''))), ''), v_type, true, v_pris, auth.uid())
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.storage_add_guest(text, text, text, boolean, text) to authenticated;

create or replace function public.storage_set_paid(p_id bigint, p_paid boolean)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.has_access('regnskap') then raise exception 'not_allowed'; end if;
  update public.storage_bikes
     set paid = coalesce(p_paid, true),
         paid_at = case when coalesce(p_paid, true) then now() end,
         paid_by_name = case when coalesce(p_paid, true) then (select name from public.members where id = auth.uid()) end
   where id = p_id;
end $$;
grant execute on function public.storage_set_paid(bigint, boolean) to authenticated;

create or replace function public.storage_remove(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
declare v_medl uuid; v_sesong text;
begin
  delete from public.storage_bikes where id = p_id
     and (member_id = auth.uid() or public._is_styre(auth.uid()) or public.has_access('regnskap'))
  returning member_id, season into v_medl, v_sesong;
  if not found then raise exception 'not_allowed'; end if;
  if v_medl is not null then perform public._lagring_prisar(v_medl, v_sesong); end if;
end $$;
grant execute on function public.storage_remove(bigint) to authenticated;
