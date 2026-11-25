-- =====================================================================
-- Medlemssida: enkelt regnskap med kvitteringar – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor (etter arkiv.sql).
-- Fila kan køyrast fleire gongar.
--
--  * Alle medlemmer ser summane; postar, kvitteringar og føring krev
--    regnskapstilgang (sjå tilgang.sql – køyr tilgang.sql på nytt etter denne fila).
--  * Kvar post: dato, konto (bank/kontant), tekst, beløp (+ inn / − ut)
--    og eventuelt ei kvittering (bilete/PDF) i Storage: arkiv/regnskap/kvitteringar/…
--  * Oversikt per år med inngåande saldo, inn, ut og utgåande saldo per konto.
-- =====================================================================

create table if not exists public.ledger (
  id              bigint generated always as identity primary key,
  dato            date not null,
  konto           text not null default 'bank',
  tekst           text not null,
  belop           numeric(12,2) not null,
  kvittering_path text,
  kvittering_namn text,
  created_by      uuid references public.members(id) on delete set null,
  created_name    text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
alter table public.ledger drop constraint if exists ledger_konto_check;
alter table public.ledger add constraint ledger_konto_check check (konto in ('bank', 'kontant'));
alter table public.ledger enable row level security;

create or replace function public._can_regnskap()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members
                  where id = auth.uid() and status = 'approved' and role in ('President', 'Treasurer'))
$$;
revoke all on function public._can_regnskap() from public, anon, authenticated;

-- Oversikt for eitt år.
-- Alle godkjende medlemmer ser summane (inn, ut, saldo). Berre dei med
-- regnskapstilgang får postane ('full' = true). (Kay 2026-11-25)
create or replace function public.ledger_year(p_year int)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_fra date := make_date(p_year, 1, 1);
  v_til date := make_date(p_year, 12, 31);
  v_full boolean := public._can_regnskap();
begin
  if not public.is_member() then raise exception 'not_allowed'; end if;
  return json_build_object(
    'year', p_year,
    'full', v_full,
    'years', (select coalesce(json_agg(y order by y desc), '[]'::json)
                from (select distinct extract(year from dato)::int as y from public.ledger
                      union select extract(year from current_date)::int) x),
    'kontoar', (select json_object_agg(k, json_build_object(
                   'inn_saldo', coalesce((select sum(belop) from public.ledger where konto = k and dato < v_fra), 0),
                   'inn', coalesce((select sum(belop) from public.ledger where konto = k and dato between v_fra and v_til and belop > 0), 0),
                   'ut', coalesce((select sum(belop) from public.ledger where konto = k and dato between v_fra and v_til and belop < 0), 0),
                   'ut_saldo', coalesce((select sum(belop) from public.ledger where konto = k and dato <= v_til), 0)))
                from unnest(array['bank', 'kontant']) k),
    'postar', coalesce((select json_agg(json_build_object(
                 'id', l.id, 'dato', l.dato, 'konto', l.konto, 'tekst', l.tekst, 'belop', l.belop,
                 'kvittering_path', l.kvittering_path, 'kvittering_namn', l.kvittering_namn,
                 'created_name', l.created_name) order by l.dato desc, l.id desc)
               from public.ledger l where v_full and l.dato between v_fra and v_til), '[]'::json));
end $$;
grant execute on function public.ledger_year(int) to authenticated;

-- Ny eller endra post. p_id = null gir ny. Returnerer id.
create or replace function public.ledger_save(p_id bigint, p_dato date, p_konto text, p_tekst text, p_belop numeric,
                                              p_kvittering_path text, p_kvittering_namn text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare
  v_id bigint;
begin
  if not public._can_regnskap() then raise exception 'not_allowed'; end if;
  p_tekst := trim(coalesce(p_tekst, ''));
  if p_dato is null then raise exception 'bad_date'; end if;
  if p_konto not in ('bank', 'kontant') then raise exception 'bad_konto'; end if;
  if length(p_tekst) < 2 or length(p_tekst) > 200 then raise exception 'bad_text'; end if;
  if p_belop is null or p_belop = 0 or abs(p_belop) > 10000000 then raise exception 'bad_amount'; end if;
  if p_kvittering_path is not null and p_kvittering_path !~ '^regnskap/kvitteringar/' then raise exception 'bad_path'; end if;

  if p_id is null then
    insert into public.ledger (dato, konto, tekst, belop, kvittering_path, kvittering_namn, created_by, created_name)
    values (p_dato, p_konto, p_tekst, round(p_belop, 2), p_kvittering_path, left(p_kvittering_namn, 200), auth.uid(),
            (select name from public.members where id = auth.uid()))
    returning id into v_id;
  else
    update public.ledger
       set dato = p_dato, konto = p_konto, tekst = p_tekst, belop = round(p_belop, 2),
           kvittering_path = coalesce(p_kvittering_path, kvittering_path),
           kvittering_namn = coalesce(left(p_kvittering_namn, 200), kvittering_namn),
           updated_at = now()
     where id = p_id
    returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;
grant execute on function public.ledger_save(bigint, date, text, text, numeric, text, text) to authenticated;

-- Slettar posten og gir tilbake kvitteringsstien (så sida kan slette fila)
create or replace function public.ledger_delete(p_id bigint)
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  v_sti text;
begin
  if not public._can_regnskap() then raise exception 'not_allowed'; end if;
  delete from public.ledger where id = p_id returning kvittering_path into v_sti;
  return v_sti;
end $$;
grant execute on function public.ledger_delete(bigint) to authenticated;
