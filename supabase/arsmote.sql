-- =====================================================================
-- Årsmøte: innmelde saker og anonym avstemming – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor ETTER styre.sql.
-- Fila kan køyrast fleire gongar.
--
-- Bestemt av Kay 2026-11-26:
--  * Alle medlemmer kan melde inn saker. Namnet står på saka, men ein kan
--    hake av «anonymt». Då blir namnet IKKJE lagra nokon stad.
--  * Ei sak går anten «Til styret – hastar» (styret får pushvarsel) eller
--    «Til årsmøtet». Styret kan merkje hastesaker som behandla.
--  * Alle medlemmer ser sakene. Styret kan fjerne useriøse saker.
--  * Alle medlemmer kan leggje inn forslag/avstemmingar med krav i prosent
--    (standard 70 %). Den som foreslo, eller styret, stengjer. Når alle med
--    røysterett har røysta, blir ho stengd av seg sjølv.
--  * Logg: vedtekne forslag kan merkjast «gjennomført».
--  * Prospect og Hangaround har ikkje røysterett (kan melde inn saker).
--  * Kvart medlem røystar ja/nei éin gong. Røysta er anonym: me lagrar
--    berre AT du har røysta (agm_voted), og tel ja/nei i to tal på
--    avstemminga. Det finst ingen kopling mellom person og svar.
--  * Resultatet blir vist når avstemminga er stengd.
-- =====================================================================

create table if not exists public.agm_cases (
  id          bigint generated always as identity primary key,
  body        text not null,
  author_id   uuid references public.members(id) on delete set null,   -- null når anonym
  author_name text,                                                     -- null når anonym
  anonymous   boolean not null default false,
  hidden      boolean not null default false,
  created_at  timestamptz not null default now()
);
alter table public.agm_cases enable row level security;
-- Kay 2026-11-26: «Til styret – hastar» eller «Til årsmøtet»
alter table public.agm_cases add column if not exists target   text    not null default 'arsmote';
alter table public.agm_cases add column if not exists handled  boolean not null default false;
alter table public.agm_cases add column if not exists notified boolean not null default false;
alter table public.agm_cases drop constraint if exists agm_cases_target_check;
alter table public.agm_cases add constraint agm_cases_target_check check (target in ('styret', 'arsmote'));

create table if not exists public.agm_votes (
  id           bigint generated always as identity primary key,
  question     text not null,
  info         text,
  krav_pct     numeric(5,2) not null,         -- t.d. 50, 66.67, 75, 100
  strict       boolean not null default false, -- true = meir enn krav (fleirtal), false = minst krav
  status       text not null default 'open' check (status in ('open', 'closed')),
  yes_count    int not null default 0,
  no_count     int not null default 0,
  created_by   uuid references public.members(id) on delete set null,
  created_name text,
  created_at   timestamptz not null default now(),
  closed_at    timestamptz
);
alter table public.agm_votes enable row level security;

-- Berre AT ein har røysta – ikkje kva, og ikkje når
create table if not exists public.agm_voted (
  vote_id   bigint not null references public.agm_votes(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  primary key (vote_id, member_id)
);
alter table public.agm_voted enable row level security;

-- Kven har røysterett: godkjende medlemmer, men IKKJE Prospect og Hangaround (Kay 2026-11-26)
create or replace function public._agm_kan_roeyste(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members
                  where id = p_id and status = 'approved' and role not in ('Prospect', 'Hangaround'))
$$;
revoke all on function public._agm_kan_roeyste(uuid) from public, anon, authenticated;

-- ---------- Saker ----------
drop function if exists public.agm_case_submit(text, boolean);
create or replace function public.agm_case_submit(p_body text, p_anonymous boolean, p_target text default 'arsmote')
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  p_body := trim(coalesce(p_body, ''));
  if length(p_body) < 3 or length(p_body) > 3000 then raise exception 'bad_text'; end if;
  if p_target not in ('styret', 'arsmote') then raise exception 'bad_target'; end if;
  if coalesce(p_anonymous, false) then
    insert into public.agm_cases (body, anonymous, target) values (p_body, true, p_target) returning id into v_id;
  else
    insert into public.agm_cases (body, author_id, author_name, anonymous, target)
    values (p_body, auth.uid(), (select name from public.members where id = auth.uid()), false, p_target)
    returning id into v_id;
  end if;
  return v_id;
end $$;
grant execute on function public.agm_case_submit(text, boolean, text) to authenticated;

create or replace function public.agm_case_list()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return coalesce((select json_agg(json_build_object(
      'id', c.id, 'body', c.body, 'author_name', c.author_name, 'anonymous', c.anonymous,
      'target', c.target, 'handled', c.handled,
      'created_at', c.created_at, 'mine', c.author_id = auth.uid()) order by c.handled, c.created_at desc)
    from public.agm_cases c where not c.hidden), '[]'::json);
end $$;
grant execute on function public.agm_case_list() to authenticated;

-- Styret merkjer ei sak som behandla (eller tek merket vekk)
create or replace function public.agm_case_handled(p_id bigint, p_handled boolean)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_styre(auth.uid()) then raise exception 'not_allowed'; end if;
  update public.agm_cases set handled = coalesce(p_handled, true) where id = p_id;
end $$;
grant execute on function public.agm_case_handled(bigint, boolean) to authenticated;

-- Styret fjernar ei sak (blir skjult, ikkje sletta)
create or replace function public.agm_case_hide(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_styre(auth.uid()) then raise exception 'not_allowed'; end if;
  update public.agm_cases set hidden = true where id = p_id;
end $$;
grant execute on function public.agm_case_hide(bigint) to authenticated;

-- ---------- Avstemming ----------
create or replace function public.agm_vote_create(p_question text, p_info text, p_krav_pct numeric, p_strict boolean)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint;
begin
  -- Kay 2026-11-26: alle godkjende medlemmer kan leggje inn forslag
  if not public.is_member() then raise exception 'not_member'; end if;
  p_question := trim(coalesce(p_question, ''));
  if length(p_question) < 3 or length(p_question) > 300 then raise exception 'bad_text'; end if;
  if p_krav_pct is null or p_krav_pct <= 0 or p_krav_pct > 100 then raise exception 'bad_krav'; end if;
  insert into public.agm_votes (question, info, krav_pct, strict, created_by, created_name)
  values (p_question, nullif(left(trim(coalesce(p_info, '')), 2000), ''), round(p_krav_pct, 2), coalesce(p_strict, false),
          auth.uid(), (select name from public.members where id = auth.uid()))
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.agm_vote_create(text, text, numeric, boolean) to authenticated;

-- Røyste. Éin gong, kan ikkje endrast. Berre tala blir auka – ingen kopling til personen.
create or replace function public.agm_vote_cast(p_id bigint, p_yes boolean)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._agm_kan_roeyste(auth.uid()) then raise exception 'no_vote_right'; end if;
  if p_yes is null then raise exception 'bad_answer'; end if;
  if not exists (select 1 from public.agm_votes where id = p_id and status = 'open') then raise exception 'closed'; end if;
  insert into public.agm_voted (vote_id, member_id) values (p_id, auth.uid()) on conflict do nothing;
  if not found then raise exception 'already_voted'; end if;
  if p_yes then
    update public.agm_votes set yes_count = yes_count + 1 where id = p_id;
  else
    update public.agm_votes set no_count = no_count + 1 where id = p_id;
  end if;
  -- Alle med røysterett har røysta → stengt av seg sjølv
  if (select count(*) from public.agm_voted where vote_id = p_id) >=
     (select count(*) from public.members where status = 'approved' and role not in ('Prospect', 'Hangaround')) then
    update public.agm_votes set status = 'closed', closed_at = now() where id = p_id and status = 'open';
  end if;
end $$;
grant execute on function public.agm_vote_cast(bigint, boolean) to authenticated;

create or replace function public.agm_vote_close(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  -- Den som la inn forslaget, eller styret
  update public.agm_votes set status = 'closed', closed_at = now()
   where id = p_id and status = 'open' and (created_by = auth.uid() or public._is_styre(auth.uid()));
  if not found then raise exception 'not_allowed'; end if;
end $$;
grant execute on function public.agm_vote_close(bigint) to authenticated;

-- Liste. Ja/nei-tala blir berre vist når avstemminga er stengd.
create or replace function public.agm_vote_list()
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_medl int := (select count(*) from public.members where status = 'approved' and role not in ('Prospect', 'Hangaround'));
  v_kan boolean := public._agm_kan_roeyste(auth.uid());
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return coalesce((select json_agg(json_build_object(
      'id', v.id, 'question', v.question, 'info', v.info, 'krav_pct', v.krav_pct, 'strict', v.strict,
      'status', v.status, 'created_name', v.created_name, 'created_at', v.created_at, 'closed_at', v.closed_at,
      'done_at', v.done_at, 'done_by_name', v.done_by_name,
      'can_close', v.created_by = auth.uid() or public._is_styre(auth.uid()),
      'voted', (select count(*) from public.agm_voted d where d.vote_id = v.id),
      'members', v_medl,
      'can_vote', v_kan,
      'i_voted', exists (select 1 from public.agm_voted d where d.vote_id = v.id and d.member_id = auth.uid()),
      'yes', case when v.status = 'closed' then v.yes_count end,
      'no', case when v.status = 'closed' then v.no_count end,
      'passed', case when v.status = 'closed' then
                  (v.yes_count + v.no_count) > 0 and
                  (case when v.strict then v.yes_count * 100.0 > v.krav_pct * (v.yes_count + v.no_count)
                        -- − 0,005 så 2/3 (lagra som 66,67) godtek nøyaktig 2 av 3
                        else v.yes_count * 100.0 >= (v.krav_pct - 0.005) * (v.yes_count + v.no_count) end) end)
      order by (v.status = 'open') desc, v.created_at desc)
    from public.agm_votes v), '[]'::json);
end $$;
grant execute on function public.agm_vote_list() to authenticated;

-- ---------- Logg: merk vedtekne forslag som gjennomførte (Kay 2026-11-26) ----------
alter table public.agm_votes add column if not exists done_at      timestamptz;
alter table public.agm_votes add column if not exists done_by_name text;

create or replace function public.agm_vote_done(p_id bigint, p_done boolean)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  update public.agm_votes
     set done_at = case when coalesce(p_done, true) then now() end,
         done_by_name = case when coalesce(p_done, true) then (select name from public.members where id = auth.uid()) end
   where id = p_id and status = 'closed' and (created_by = auth.uid() or public._is_styre(auth.uid()));
  if not found then raise exception 'not_allowed'; end if;
end $$;
grant execute on function public.agm_vote_done(bigint, boolean) to authenticated;