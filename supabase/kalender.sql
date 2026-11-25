-- =====================================================================
-- Medlemssida: kalender – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor (etter chat.sql).
-- Fila kan køyrast fleire gongar.
--
--  * Fråvær: kvar medlem legg inn når dei er på jobb, ferie eller bortreist.
--  * Treff/arrangement: alle medlemmer kan leggje inn (òg treff andre klubbar
--    held). Endre/slette: den som la det inn, eller President / Vice President.
--  * Svar Ja/Nei per medlem. Treffet kan delast i chatten med Ja/Nei-knappar.
-- =====================================================================

create table if not exists public.absences (
  id          bigint generated always as identity primary key,
  member_id   uuid not null references public.members(id) on delete cascade,
  fra         date not null,
  til         date not null,
  type        text not null,
  note        text,
  created_at  timestamptz not null default now()
);
alter table public.absences drop constraint if exists absences_type_check;
alter table public.absences add constraint absences_type_check check (type in ('jobb', 'ferie', 'vekk'));
alter table public.absences enable row level security;

create table if not exists public.events (
  id            bigint generated always as identity primary key,
  title         text not null,
  dato          date not null,
  tid           time,
  til_dato      date,
  place         text,
  link          text,
  info          text,
  arranger      text,
  created_by    uuid references public.members(id) on delete set null,
  created_name  text,
  created_at    timestamptz not null default now()
);
alter table public.events enable row level security;

create table if not exists public.event_rsvp (
  event_id    bigint not null references public.events(id) on delete cascade,
  member_id   uuid not null references public.members(id) on delete cascade,
  svar        boolean not null,
  updated_at  timestamptz not null default now(),
  primary key (event_id, member_id)
);
alter table public.event_rsvp enable row level security;

alter table public.chat_messages add column if not exists event_id bigint references public.events(id) on delete set null;

-- Treff som JSON (brukt både i kalenderen og i chatten)
create or replace function public._event_json(p_id bigint)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', e.id, 'title', e.title, 'dato', e.dato, 'tid', to_char(e.tid, 'HH24:MI'), 'til_dato', e.til_dato,
    'place', e.place, 'link', e.link, 'info', e.info, 'arranger', e.arranger,
    'created_by', e.created_by, 'created_name', e.created_name,
    'ja', coalesce((select json_agg(m.name order by m.name) from public.event_rsvp r
                     join public.members m on m.id = r.member_id and m.status = 'approved'
                    where r.event_id = e.id and r.svar), '[]'::json),
    'nei', coalesce((select json_agg(m.name order by m.name) from public.event_rsvp r
                      join public.members m on m.id = r.member_id and m.status = 'approved'
                     where r.event_id = e.id and not r.svar), '[]'::json),
    'mitt', (select r.svar from public.event_rsvp r where r.event_id = e.id and r.member_id = auth.uid()),
    -- Medlemmer som har lagt inn fråvær ein av dagane treffet varer
    'borte', coalesce((select json_agg(json_build_object('name', m.name, 'type', a.type) order by m.name)
                        from public.absences a join public.members m on m.id = a.member_id and m.status = 'approved'
                       where a.fra <= coalesce(e.til_dato, e.dato) and a.til >= e.dato), '[]'::json))
  from public.events e where e.id = p_id
$$;
revoke all on function public._event_json(bigint) from public, anon, authenticated;

-- Alt i eit tidsrom (månaden som blir vist)
create or replace function public.cal_range(p_fra date, p_til date)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return json_build_object(
    'events', coalesce((select json_agg(public._event_json(e.id) order by e.dato, e.tid nulls first)
                          from public.events e
                         where e.dato <= p_til and coalesce(e.til_dato, e.dato) >= p_fra), '[]'::json),
    'absences', coalesce((select json_agg(json_build_object(
                             'id', a.id, 'member_id', a.member_id, 'name', m.name, 'fra', a.fra, 'til', a.til,
                             'type', a.type, 'note', a.note) order by a.fra, m.name)
                            from public.absences a join public.members m on m.id = a.member_id and m.status = 'approved'
                           where a.fra <= p_til and a.til >= p_fra), '[]'::json),
    'mine_fravaer', coalesce((select json_agg(json_build_object('id', a.id, 'fra', a.fra, 'til', a.til, 'type', a.type, 'note', a.note)
                               order by a.fra) from public.absences a
                              where a.member_id = auth.uid() and a.til >= current_date), '[]'::json));
end $$;
grant execute on function public.cal_range(date, date) to authenticated;

-- ---------- Fråvær (berre eige) ----------
create or replace function public.absence_save(p_id bigint, p_fra date, p_til date, p_type text, p_note text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare
  v_id bigint;
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  if p_fra is null or p_til is null or p_til < p_fra then raise exception 'bad_dates'; end if;
  if p_til - p_fra > 366 then raise exception 'too_long'; end if;
  if p_type not in ('jobb', 'ferie', 'vekk') then raise exception 'bad_type'; end if;
  p_note := nullif(left(trim(coalesce(p_note, '')), 200), '');
  if p_id is null then
    insert into public.absences (member_id, fra, til, type, note) values (auth.uid(), p_fra, p_til, p_type, p_note)
    returning id into v_id;
  else
    update public.absences set fra = p_fra, til = p_til, type = p_type, note = p_note
     where id = p_id and member_id = auth.uid() returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;
grant execute on function public.absence_save(bigint, date, date, text, text) to authenticated;

create or replace function public.absence_delete(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  delete from public.absences where id = p_id and (member_id = auth.uid() or public._is_member_leader());
end $$;
grant execute on function public.absence_delete(bigint) to authenticated;

-- ---------- Treff ----------
create or replace function public.event_save(p_id bigint, p_title text, p_dato date, p_tid time, p_til_dato date,
                                             p_place text, p_link text, p_info text, p_arranger text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare
  v_id bigint;
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  p_title := trim(coalesce(p_title, ''));
  if length(p_title) < 2 or length(p_title) > 120 then raise exception 'bad_title'; end if;
  if p_dato is null then raise exception 'bad_dates'; end if;
  if p_til_dato is not null and (p_til_dato < p_dato or p_til_dato - p_dato > 31) then raise exception 'bad_dates'; end if;
  p_link := nullif(trim(coalesce(p_link, '')), '');
  if p_link is not null and p_link !~ '^https://[^\s<>"]+$' then raise exception 'bad_link'; end if;
  p_place := nullif(left(trim(coalesce(p_place, '')), 120), '');
  p_info := nullif(left(trim(coalesce(p_info, '')), 2000), '');
  p_arranger := nullif(left(trim(coalesce(p_arranger, '')), 80), '');
  if p_id is null then
    insert into public.events (title, dato, tid, til_dato, place, link, info, arranger, created_by, created_name)
    values (p_title, p_dato, p_tid, p_til_dato, p_place, p_link, p_info, p_arranger, auth.uid(),
            (select name from public.members where id = auth.uid()))
    returning id into v_id;
  else
    update public.events set title = p_title, dato = p_dato, tid = p_tid, til_dato = p_til_dato,
           place = p_place, link = p_link, info = p_info, arranger = p_arranger
     where id = p_id and (created_by = auth.uid() or public._is_member_leader())
    returning id into v_id;
    if v_id is null then raise exception 'not_allowed'; end if;
  end if;
  return v_id;
end $$;
grant execute on function public.event_save(bigint, text, date, time, date, text, text, text, text) to authenticated;

create or replace function public.event_delete(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  delete from public.events where id = p_id and (created_by = auth.uid() or public._is_member_leader());
  if not found then raise exception 'not_allowed'; end if;
end $$;
grant execute on function public.event_delete(bigint) to authenticated;

create or replace function public.event_answer(p_id bigint, p_svar boolean)
returns json language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  if not exists (select 1 from public.events where id = p_id) then raise exception 'not_found'; end if;
  if p_svar is null then
    delete from public.event_rsvp where event_id = p_id and member_id = auth.uid();
  else
    insert into public.event_rsvp (event_id, member_id, svar) values (p_id, auth.uid(), p_svar)
    on conflict (event_id, member_id) do update set svar = excluded.svar, updated_at = now();
  end if;
  return public._event_json(p_id);
end $$;
grant execute on function public.event_answer(bigint, boolean) to authenticated;

-- Del treffet i chatten. Returnerer id på chat-meldinga (sida sender så varsel).
create or replace function public.event_share(p_id bigint)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare
  v_e public.events;
  v_tekst text;
  v_id bigint;
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  select * into v_e from public.events where id = p_id;
  if not found then raise exception 'not_found'; end if;
  v_tekst := '📅 ' || v_e.title || ' – ' || to_char(v_e.dato, 'DD.MM.YYYY')
             || coalesce(' kl. ' || to_char(v_e.tid, 'HH24:MI'), '')
             || coalesce(' (' || v_e.arranger || ')', '') || E'\nKan du vere med?';
  insert into public.chat_messages (author_id, body, event_id) values (auth.uid(), v_tekst, p_id) returning id into v_id;
  insert into public.chat_reads (member_id, last_read_id) values (auth.uid(), v_id)
  on conflict (member_id) do update set last_read_id = greatest(chat_reads.last_read_id, excluded.last_read_id), updated_at = now();
  return v_id;
end $$;
grant execute on function public.event_share(bigint) to authenticated;

-- chat_list får med treffet når ei melding er ei deling
create or replace function public.chat_list(p_after bigint default 0)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_total int;
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  select count(*) into v_total from public.members where status = 'approved';
  return json_build_object(
    'total', v_total,
    'my_last_read', coalesce((select last_read_id from public.chat_reads where member_id = auth.uid()), 0),
    'messages', coalesce((
      select json_agg(json_build_object(
               'id', x.id, 'body', x.body, 'created_at', x.created_at,
               'author_id', x.author_id, 'author', coalesce(m.name, 'Tidlegare medlem'),
               'event', case when x.event_id is not null then public._event_json(x.event_id) end,
               'seen', (select count(*) from public.chat_reads r
                          join public.members mm on mm.id = r.member_id and mm.status = 'approved'
                         where r.last_read_id >= x.id))
             order by x.id)
      from (select * from public.chat_messages
             where id > coalesce(p_after, 0)
             order by id desc limit 100) x
      left join public.members m on m.id = x.author_id
    ), '[]'::json));
end $$;
grant execute on function public.chat_list(bigint) to authenticated;
