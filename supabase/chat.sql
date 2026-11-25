-- =====================================================================
-- Medlemssida steg 2: chat med varsel – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor (etter medlem.sql).
-- Fila kan køyrast fleire gongar.
--
--  * Éin felles chat for godkjende medlemmer.
--  * «Sett av»: kvar medlem har ein «lest til og med»-id.
--  * Push-varsel: mobilane registrerer seg i push_subscriptions.
--    Edge-funksjonen «chat-push» sender varsel til alle utanom avsendaren.
--    VAPID-nøklane blir laga av funksjonen sjølv og ligg i push_config,
--    som berre funksjonen (service role) kan lese.
-- =====================================================================

create table if not exists public.chat_messages (
  id          bigint generated always as identity primary key,
  author_id   uuid references public.members(id) on delete set null,
  body        text not null,
  created_at  timestamptz not null default now()
);
alter table public.chat_messages enable row level security;

create table if not exists public.chat_reads (
  member_id    uuid primary key references public.members(id) on delete cascade,
  last_read_id bigint not null default 0,
  updated_at   timestamptz not null default now()
);
alter table public.chat_reads enable row level security;

create table if not exists public.push_subscriptions (
  endpoint    text primary key,
  member_id   uuid not null references public.members(id) on delete cascade,
  p256dh      text not null,
  auth        text not null,
  user_agent  text,
  created_at  timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;

create table if not exists public.push_config (
  id           int primary key default 1 check (id = 1),
  public_key   text not null,
  private_key  text not null,
  created_at   timestamptz not null default now()
);
alter table public.push_config enable row level security;
-- Ingen policyar: berre funksjonane under og edge-funksjonen (service role) slepp til.

-- ---------- Chat ----------
-- Meldingar etter p_after (eller dei 100 siste når p_after = 0),
-- med namn på avsendar og kor mange som har sett meldinga.
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

-- Oppdater «sett av»-tal for meldingar som alt er viste (lett spørjing)
create or replace function public.chat_seen_counts(p_from bigint)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return coalesce((
    select json_object_agg(x.id, (select count(*) from public.chat_reads r
                                    join public.members mm on mm.id = r.member_id and mm.status = 'approved'
                                   where r.last_read_id >= x.id))
    from public.chat_messages x where x.id >= coalesce(p_from, 0)), '{}'::json);
end $$;
grant execute on function public.chat_seen_counts(bigint) to authenticated;

create or replace function public.chat_send(p_body text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare
  v_id bigint;
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  p_body := trim(coalesce(p_body, ''));
  if length(p_body) < 1 or length(p_body) > 2000 then raise exception 'bad_body'; end if;
  insert into public.chat_messages (author_id, body) values (auth.uid(), p_body) returning id into v_id;
  -- Avsendaren har sjølvsagt sett si eiga melding
  insert into public.chat_reads (member_id, last_read_id) values (auth.uid(), v_id)
  on conflict (member_id) do update set last_read_id = greatest(chat_reads.last_read_id, excluded.last_read_id), updated_at = now();
  return v_id;
end $$;
grant execute on function public.chat_send(text) to authenticated;

create or replace function public.chat_mark_read(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  insert into public.chat_reads (member_id, last_read_id) values (auth.uid(), coalesce(p_id, 0))
  on conflict (member_id) do update set last_read_id = greatest(chat_reads.last_read_id, excluded.last_read_id), updated_at = now();
end $$;
grant execute on function public.chat_mark_read(bigint) to authenticated;

-- Kven har sett / ikkje sett ei melding
create or replace function public.chat_seen_by(p_id bigint)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  return json_build_object(
    'seen', coalesce((select json_agg(m.name order by m.name) from public.members m
                       join public.chat_reads r on r.member_id = m.id
                      where m.status = 'approved' and r.last_read_id >= p_id), '[]'::json),
    'not_seen', coalesce((select json_agg(m.name order by m.name) from public.members m
                           left join public.chat_reads r on r.member_id = m.id
                          where m.status = 'approved' and coalesce(r.last_read_id, 0) < p_id), '[]'::json));
end $$;
grant execute on function public.chat_seen_by(bigint) to authenticated;

-- ---------- Push-varsel ----------
-- Berre kjende push-tenester er lov (Google/Chrome, Firefox, Apple, Microsoft)
create or replace function public.push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_ua text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not_member'; end if;
  if p_endpoint !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9.-]*push\.apple\.com|[a-z0-9.-]*\.notify\.windows\.com)/' then
    raise exception 'bad_endpoint';
  end if;
  if length(coalesce(p_p256dh, '')) < 20 or length(coalesce(p_auth, '')) < 8 then raise exception 'bad_keys'; end if;
  insert into public.push_subscriptions (endpoint, member_id, p256dh, auth, user_agent)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth, left(p_ua, 300))
  on conflict (endpoint) do update set member_id = auth.uid(), p256dh = excluded.p256dh,
                                       auth = excluded.auth, user_agent = excluded.user_agent;
end $$;
grant execute on function public.push_subscribe(text, text, text, text) to authenticated;

create or replace function public.push_unsubscribe(p_endpoint text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  delete from public.push_subscriptions where endpoint = p_endpoint and member_id = auth.uid();
end $$;
grant execute on function public.push_unsubscribe(text) to authenticated;

-- Offentleg VAPID-nøkkel (null til edge-funksjonen har laga nøklane)
create or replace function public.push_public_key()
returns text language sql stable security definer set search_path = public as $$
  select public_key from public.push_config where id = 1
$$;
grant execute on function public.push_public_key() to authenticated;
