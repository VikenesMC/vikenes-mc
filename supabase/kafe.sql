-- =====================================================================
-- Torsdagskafé: automatisk arrangement i chatten kvar torsdag kl. 16:30
-- Køyr heile fila i Supabase → SQL Editor ETTER kalender.sql og chat.sql.
-- Fila kan køyrast fleire gongar.
--
-- Kay 2026-11-26:
--  * Kvar torsdag kl. 16:30 (norsk tid) kjem «Kjem du på kafé i kveld?» i
--    chatten som eit arrangement (Torsdagskafé kl. 18:00) med Ja/Nei.
--  * Alle godkjende medlemmer kan svare – også Prospect og Hangaround.
--  * Alle får pushvarsel (edge-funksjonen chat-push, action «kafe»).
--  * pg_cron køyrer 14:30 og 15:30 UTC (sommar- og vintertid); funksjonen
--    sjekkar sjølv at klokka i Oslo er 16 og at det ikkje alt er laga i dag.
-- =====================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

alter table public.cal_events add column if not exists auto boolean not null default false;
alter table public.chat_messages add column if not exists system boolean not null default false;
alter table public.push_config add column if not exists cron_secret text;
update public.push_config set cron_secret = encode(extensions.gen_random_bytes(24), 'hex') where cron_secret is null;

-- Lagar dagens torsdagskafé og legg han i chatten. Returnerer meldings-id (null om ikkje laga).
create or replace function public.kafe_auto(p_tving boolean default false)
returns bigint language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_no     timestamp := now() at time zone 'Europe/Oslo';
  v_dag    date := (now() at time zone 'Europe/Oslo')::date;
  v_ev     bigint;
  v_msg    bigint;
  v_secret text;
begin
  if not p_tving and (extract(isodow from v_no) <> 4 or extract(hour from v_no) <> 16) then
    return null;
  end if;
  if exists (select 1 from public.cal_events where auto and dato = v_dag) then
    return null;
  end if;

  insert into public.cal_events (title, dato, tid, place, arranger, info, created_name, auto)
  values ('Torsdagskafé', v_dag, '18:00', 'Vikeneset, Volda', 'Vikenes MC',
          'Kaffi og ein prat i klubbhuset.', 'Vikenes MC', true)
  returning id into v_ev;

  insert into public.chat_messages (author_id, body, event_id, system)
  values (null, E'☕ Torsdagskafé i kveld kl. 18:00\nKjem du på kafé i kveld?', v_ev, true)
  returning id into v_msg;

  -- Pushvarsel til alle (via edge-funksjonen)
  select cron_secret into v_secret from public.push_config where id = 1;
  if v_secret is not null then
    perform net.http_post(
      url := 'https://yrozxcxjqxfwbbdwlwwi.supabase.co/functions/v1/chat-push',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-kafe-secret', v_secret),
      body := jsonb_build_object('action', 'kafe', 'message_id', v_msg));
  end if;
  return v_msg;
end $$;
revoke all on function public.kafe_auto(boolean) from public, anon, authenticated;

-- Timeplan: torsdagar 14:30 og 15:30 UTC (= 16:30 norsk tid sommar/vinter)
select cron.unschedule(jobid) from cron.job where jobname = 'torsdagskafe';
select cron.schedule('torsdagskafe', '30 14,15 * * 4', 'select public.kafe_auto()');

-- chat_list: automatiske meldingar står frå «Vikenes MC»
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
               'author_id', x.author_id,
               'author', case when x.system then 'Vikenes MC' else coalesce(m.name, 'Tidlegare medlem') end,
               'system', x.system,
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
