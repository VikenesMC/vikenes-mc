-- =====================================================================
-- Nye medlemmer berre via QR-kode frå President – Vikenes MC
-- Køyr heile fila i Supabase → SQL Editor (etter medlem.sql).
-- Fila kan køyrast fleire gongar.
--
--  * President lagar ein invitasjonskode (gyldig i 24 timar) som blir
--    vist som QR-kode på medlemssida. Ny medlem skannar og registrerer seg.
--  * Utan gyldig kode kan ingen registrere seg i medlemsregisteret.
--  * Nye medlemmer må framleis godkjennast før dei kjem inn.
-- =====================================================================

create table if not exists public.member_invites (
  token       text primary key,
  created_by  uuid references public.members(id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null
);
alter table public.member_invites enable row level security;

-- Berre President kan lage invitasjon
create or replace function public.invite_create()
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  v_token text := public.ny_kode(24);
  v_utlop timestamptz := now() + interval '24 hours';
begin
  if not exists (select 1 from public.members where id = auth.uid() and status = 'approved' and role = 'President') then
    raise exception 'not_allowed';
  end if;
  delete from public.member_invites where expires_at < now();
  insert into public.member_invites (token, created_by, expires_at) values (v_token, auth.uid(), v_utlop);
  return json_build_object('token', v_token, 'expires_at', v_utlop);
end $$;
grant execute on function public.invite_create() to authenticated;

create or replace function public.invite_valid(p_token text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.member_invites where token = p_token and expires_at > now())
$$;
grant execute on function public.invite_valid(text) to anon, authenticated;

-- Registrering krev no gyldig invitasjonskode
drop function if exists public.member_register(text, text);
create or replace function public.member_register(p_name text, p_phone text, p_token text default null)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  v_tlf text;
  v_rad public.members;
begin
  if auth.uid() is null then
    return json_build_object('status', 'not_logged_in');
  end if;

  select * into v_rad from public.members where id = auth.uid();
  if found then
    p_name := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
    v_tlf := public._norm_tlf(p_phone);
    if v_rad.status = 'pending' and length(p_name) between 2 and 80 and v_tlf ~ '^[0-9]{8}$' then
      update public.members set name = p_name, phone = v_tlf where id = auth.uid();
    end if;
    return json_build_object('status', v_rad.status);
  end if;

  if not public.invite_valid(p_token) then
    return json_build_object('status', 'bad_invite');
  end if;

  p_name := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if length(p_name) < 2 or length(p_name) > 80 then
    return json_build_object('status', 'bad_name');
  end if;
  v_tlf := public._norm_tlf(p_phone);
  if v_tlf !~ '^[0-9]{8}$' then
    return json_build_object('status', 'bad_phone');
  end if;
  if exists (select 1 from public.members where phone = v_tlf and status <> 'removed') then
    return json_build_object('status', 'phone_exists');
  end if;

  insert into public.members (id, name, phone, email)
  values (auth.uid(), p_name, v_tlf, auth.jwt() ->> 'email');
  return json_build_object('status', 'pending');
end $$;
grant execute on function public.member_register(text, text, text) to authenticated;
