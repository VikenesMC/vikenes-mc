-- =====================================================================
-- Medlemssida: arkiv/dokument – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor (etter medlem.sql og nyheiter.sql).
-- Fila kan køyrast fleire gongar.
--
-- Mapper (faste): reglar, vedtekter, hus-lokale, arsmote, regnskap
--  * Alle godkjende medlemmer ser og opnar dokument (utanom regnskap).
--  * President og Vice President lastar opp og slettar (utanom regnskap).
--  * Regnskap: berre President og Treasurer – både sjå, laste opp og slette.
-- Filene ligg i Supabase Storage (bøtta «arkiv», privat). Opning skjer med
-- tidsavgrensa lenkjer, så ingen kan dele ei fast lenkje til eit dokument.
-- =====================================================================

create or replace function public.arkiv_mapper()
returns text[] language sql immutable as $$
  select array['reglar', 'vedtekter', 'hus-lokale', 'arsmote', 'regnskap']
$$;

create or replace function public.can_see_folder(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_folder = any (public.arkiv_mapper())
     and exists (select 1 from public.members m
                  where m.id = auth.uid() and m.status = 'approved'
                    and (p_folder <> 'regnskap' or m.role in ('President', 'Treasurer')))
$$;
grant execute on function public.can_see_folder(text) to authenticated;

create or replace function public.can_write_folder(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_folder = any (public.arkiv_mapper())
     and exists (select 1 from public.members m
                  where m.id = auth.uid() and m.status = 'approved'
                    and ((p_folder <> 'regnskap' and m.role in ('President', 'Vice President'))
                      or (p_folder = 'regnskap' and m.role in ('President', 'Treasurer'))))
$$;
grant execute on function public.can_write_folder(text) to authenticated;

-- ---------- Dokumentliste ----------
create table if not exists public.documents (
  id            bigint generated always as identity primary key,
  folder        text not null,
  path          text not null unique,
  name          text not null,
  size          bigint,
  mime          text,
  uploaded_by   uuid references public.members(id) on delete set null,
  uploader_name text,
  created_at    timestamptz not null default now()
);
alter table public.documents enable row level security;

create or replace function public.doc_list(p_folder text)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_see_folder(p_folder) then raise exception 'not_allowed'; end if;
  return coalesce((select json_agg(json_build_object(
           'id', d.id, 'path', d.path, 'name', d.name, 'size', d.size, 'mime', d.mime,
           'uploader', d.uploader_name, 'created_at', d.created_at) order by d.created_at desc)
         from public.documents d where d.folder = p_folder), '[]'::json);
end $$;
grant execute on function public.doc_list(text) to authenticated;

create or replace function public.doc_add(p_folder text, p_path text, p_name text, p_size bigint, p_mime text)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare
  v_id bigint;
begin
  if not public.can_write_folder(p_folder) then raise exception 'not_allowed'; end if;
  if p_path is null or left(p_path, length(p_folder) + 1) <> p_folder || '/' then raise exception 'bad_path'; end if;
  p_name := trim(coalesce(p_name, ''));
  if length(p_name) < 1 or length(p_name) > 200 then raise exception 'bad_name'; end if;
  insert into public.documents (folder, path, name, size, mime, uploaded_by, uploader_name)
  values (p_folder, p_path, p_name, p_size, left(p_mime, 100), auth.uid(),
          (select name from public.members where id = auth.uid()))
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.doc_add(text, text, text, bigint, text) to authenticated;

-- Slettar raden og gir tilbake stien, så sida kan slette sjølve fila i Storage
create or replace function public.doc_delete(p_id bigint)
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  v_doc public.documents;
begin
  select * into v_doc from public.documents where id = p_id;
  if not found then raise exception 'not_found'; end if;
  if not public.can_write_folder(v_doc.folder) then raise exception 'not_allowed'; end if;
  delete from public.documents where id = p_id;
  return v_doc.path;
end $$;
grant execute on function public.doc_delete(bigint) to authenticated;

-- ---------- member_me med alle løyve ----------
create or replace function public.member_me()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', m.id, 'name', m.name, 'phone', m.phone, 'email', m.email,
    'role', m.role, 'status', m.status,
    'leader', (m.status = 'approved' and m.role in ('President', 'Vice President')),
    'news_writer', (m.status = 'approved' and m.role in ('President', 'Vice President', 'Secretary')),
    'regnskap', (m.status = 'approved' and m.role in ('President', 'Treasurer')))
  from public.members m where m.id = auth.uid()
$$;
grant execute on function public.member_me() to authenticated;

-- ---------- Storage: privat bøtte «arkiv» (maks 25 MB per fil) ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('arkiv', 'arkiv', false, 26214400)
on conflict (id) do update set public = false, file_size_limit = 26214400;

drop policy if exists "arkiv_les" on storage.objects;
drop policy if exists "arkiv_last_opp" on storage.objects;
drop policy if exists "arkiv_slett" on storage.objects;

create policy "arkiv_les" on storage.objects for select to authenticated
  using (bucket_id = 'arkiv' and public.can_see_folder((storage.foldername(name))[1]));

create policy "arkiv_last_opp" on storage.objects for insert to authenticated
  with check (bucket_id = 'arkiv' and public.can_write_folder((storage.foldername(name))[1]));

create policy "arkiv_slett" on storage.objects for delete to authenticated
  using (bucket_id = 'arkiv' and public.can_write_folder((storage.foldername(name))[1]));
