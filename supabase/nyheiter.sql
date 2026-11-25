-- =====================================================================
-- Nyheiter på heimesida – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor (etter medlem.sql).
-- Fila kan køyrast fleire gongar.
--
--  * President, Vice President og Secretary skriv og publiserer frå
--    medlemssida. Publiserte saker blir viste på heimesida for alle.
--  * Tabellen kan ikkje lesast direkte – berre gjennom funksjonane.
-- =====================================================================

create table if not exists public.news (
  id           bigint generated always as identity primary key,
  title        text not null,
  body         text not null default '',
  link_url     text,
  link_text    text,
  published    boolean not null default false,
  created_at   timestamptz not null default now(),
  published_at timestamptz,
  updated_at   timestamptz not null default now(),
  author_id    uuid references public.members(id) on delete set null,
  author_name  text
);
alter table public.news enable row level security;

-- Kven kan skrive nyheiter
create or replace function public._is_news_writer()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members
                 where id = auth.uid() and status = 'approved'
                   and role in ('President', 'Vice President', 'Secretary'))
$$;
revoke all on function public._is_news_writer() from public, anon, authenticated;

-- member_me får eit ekstra felt: news_writer
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

-- Heimesida (alle): dei 10 nyaste publiserte sakene
create or replace function public.news_public()
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'id', n.id, 'title', n.title, 'body', n.body,
           'link_url', n.link_url, 'link_text', n.link_text,
           'published_at', n.published_at) order by n.published_at desc), '[]'::json)
  from (select * from public.news where published
        order by published_at desc limit 10) n
$$;
grant execute on function public.news_public() to anon, authenticated;

-- Medlemssida (skribentar): alle saker, òg kladdar
create or replace function public.news_all()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_news_writer() then raise exception 'not_allowed'; end if;
  return coalesce((select json_agg(json_build_object(
           'id', n.id, 'title', n.title, 'body', n.body,
           'link_url', n.link_url, 'link_text', n.link_text,
           'published', n.published, 'published_at', n.published_at,
           'created_at', n.created_at, 'author_name', n.author_name)
           order by coalesce(n.published_at, n.created_at) desc)
         from public.news n), '[]'::json);
end $$;
grant execute on function public.news_all() to authenticated;

-- Lagre ny eller endra sak. p_id = null gir ny sak. Returnerer id.
create or replace function public.news_save(p_id bigint, p_title text, p_body text,
                                            p_link_url text, p_link_text text, p_published boolean)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare
  v_id bigint;
  v_namn text;
begin
  if not public._is_news_writer() then raise exception 'not_allowed'; end if;
  p_title := trim(coalesce(p_title, ''));
  p_body := trim(coalesce(p_body, ''));
  p_link_url := nullif(trim(coalesce(p_link_url, '')), '');
  p_link_text := nullif(trim(coalesce(p_link_text, '')), '');
  if length(p_title) < 2 or length(p_title) > 120 then raise exception 'bad_title'; end if;
  if length(p_body) > 5000 then raise exception 'bad_body'; end if;
  -- Lenkje: berre https://… eller ei side på vår eiga nettside (t.d. quiz.html)
  if p_link_url is not null and p_link_url !~ '^(https://[^\s<>"]+|[a-z0-9_\-]+\.html(\?[^\s<>"]*)?)$' then
    raise exception 'bad_link';
  end if;
  select name into v_namn from public.members where id = auth.uid();

  if p_id is null then
    insert into public.news (title, body, link_url, link_text, published, published_at, author_id, author_name)
    values (p_title, p_body, p_link_url, p_link_text, coalesce(p_published, false),
            case when p_published then now() end, auth.uid(), v_namn)
    returning id into v_id;
  else
    update public.news
       set title = p_title, body = p_body, link_url = p_link_url, link_text = p_link_text,
           published_at = case when p_published and not published then now()
                                when not p_published then null else published_at end,
           published = coalesce(p_published, false),
           updated_at = now()
     where id = p_id
    returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;
grant execute on function public.news_save(bigint, text, text, text, text, boolean) to authenticated;

create or replace function public.news_delete(p_id bigint)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_news_writer() then raise exception 'not_allowed'; end if;
  delete from public.news where id = p_id;
end $$;
grant execute on function public.news_delete(bigint) to authenticated;
