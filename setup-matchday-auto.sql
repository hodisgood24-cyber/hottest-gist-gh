-- Hottest Gist GH: bring in real matches automatically (fixtures, live scores and results).
-- Run AFTER setup-matchday.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.
-- Matches come from ESPN's public scoreboard feed: about 30 leagues, from yesterday to 10 days ahead.
-- Everything updates every 5 minutes, and live games also update while people have Match day open.
-- The first run can take a minute.

create extension if not exists http with schema extensions;

alter table matches add column if not exists ext_id text;
alter table matches add column if not exists home_logo text;
alter table matches add column if not exists away_logo text;
create unique index if not exists matches_ext_id on matches (ext_id);

-- Which competitions to bring in. ghana_only = only matches with Ghana playing.
create table if not exists match_sources (
  code text primary key,
  label text not null,
  ghana_only boolean not null default false,
  enabled boolean not null default true
);
alter table match_sources add column if not exists last_at timestamptz;
alter table match_sources add column if not exists prio int not null default 50;
insert into match_sources (code, label, ghana_only, prio) values
  ('fifa.friendly',       'International friendly',  false, 1),
  ('fifa.worldq.caf',     'World Cup qualifier',     false, 2),
  ('caf.nations',         'AFCON',                   false, 3),
  ('caf.nations_qual',    'AFCON qualifier',         false, 4),
  ('gha.1',               'Ghana Premier League',    false, 5),
  ('eng.1',               'Premier League',          false, 6),
  ('uefa.champions',      'Champions League',        false, 7),
  ('esp.1',               'La Liga',                 false, 8),
  ('ita.1',               'Serie A',                 false, 9),
  ('ger.1',               'Bundesliga',              false, 10),
  ('fra.1',               'Ligue 1',                 false, 11),
  ('uefa.europa',         'Europa League',           false, 12),
  ('uefa.europa.conf',    'Conference League',       false, 13),
  ('caf.champions',       'CAF Champions League',    false, 14),
  ('caf.confed',          'CAF Confederation Cup',   false, 15),
  ('eng.2',               'Championship',            false, 16),
  ('eng.fa',              'FA Cup',                  false, 17),
  ('eng.league_cup',      'Carabao Cup',             false, 18),
  ('esp.copa_del_rey',    'Copa del Rey',            false, 19),
  ('ned.1',               'Eredivisie',              false, 20),
  ('por.1',               'Liga Portugal',           false, 21),
  ('sco.1',               'Scottish Premiership',    false, 22),
  ('tur.1',               'Turkish Super Lig',       false, 23),
  ('sau.1',               'Saudi Pro League',        false, 24),
  ('usa.1',               'MLS',                     false, 25),
  ('nga.1',               'Nigeria Premier League',  false, 26),
  ('rsa.1',               'South Africa PSL',        false, 27),
  ('egy.1',               'Egyptian Premier League', false, 28),
  ('bra.1',               'Brasileirao',             false, 29),
  ('arg.1',               'Argentina Primera',       false, 30),
  ('mex.1',               'Liga MX',                 false, 31)
on conflict (code) do update set label = excluded.label, ghana_only = excluded.ghana_only, prio = excluded.prio, enabled = true;
alter table match_sources enable row level security;
revoke all on match_sources from anon, authenticated;
-- Earlier versions called Ghana friendlies "Black Stars"
update matches set competition = 'International friendly' where ext_id like 'fifa.friendly:%' and competition = 'Black Stars';

create table if not exists match_sync (id int primary key default 1, last_at timestamptz, last_note text);
insert into match_sync (id) values (1) on conflict do nothing;
alter table match_sync enable row level security;
revoke all on match_sync from anon, authenticated;

-- Fetch the next 7 days (and yesterday) for every competition and save them
drop function if exists sync_matches();
create or replace function sync_matches(p_max int default 100) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  s record; ev jsonb; c jsonb; h jsonb; a jsonb; st text; nm text; js jsonb; res record;
  d1 text := to_char((now() at time zone 'utc') - interval '1 day', 'YYYYMMDD');
  d2 text := to_char((now() at time zone 'utc') + interval '10 days', 'YYYYMMDD');
  n int := 0; bad text := ''; why text := '';
begin
  if not pg_try_advisory_xact_lock(424242) then return 'busy'; end if;
  perform http_set_curlopt('CURLOPT_TIMEOUT', '6');
  for s in select * from match_sources ms where enabled
           order by exists (select 1 from matches m where m.ext_id like ms.code || ':%' and (m.status = 'live'
                     or (m.status = 'upcoming' and m.kickoff < now()))) desc,
                    ms.last_at nulls first, ms.prio
           limit greatest(p_max, 1) loop
    update match_sources set last_at = now() where code = s.code;
    begin
      select * into res from http(('GET',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/' || s.code || '/scoreboard?limit=300&dates=' || d1 || '-' || d2,
        array[http_header('User-Agent', 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36'),
              http_header('Accept', 'application/json')],
        null, null)::http_request);
      if res.status <> 200 then
        bad := bad || s.code || ' ';
        if why = '' then why := s.code || ' answered ' || res.status || ': ' || left(regexp_replace(coalesce(res.content, ''), '\s+', ' ', 'g'), 120); end if;
        continue;
      end if;
      js := res.content::jsonb;
      for ev in select * from jsonb_array_elements(coalesce(js->'events', '[]'::jsonb)) loop
        c := ev->'competitions'->0;
        select x into h from jsonb_array_elements(c->'competitors') x where x->>'homeAway' = 'home' limit 1;
        select x into a from jsonb_array_elements(c->'competitors') x where x->>'homeAway' = 'away' limit 1;
        if h is null or a is null then continue; end if;
        if s.ghana_only and not (h->'team'->>'displayName' ilike 'Ghana%' or a->'team'->>'displayName' ilike 'Ghana%') then continue; end if;
        nm := ev->'status'->'type'->>'name';
        st := case
          when nm in ('STATUS_POSTPONED', 'STATUS_CANCELED', 'STATUS_SUSPENDED', 'STATUS_ABANDONED') then 'postponed'
          when ev->'status'->'type'->>'state' = 'in' then 'live'
          when ev->'status'->'type'->>'state' = 'post' then 'finished'
          else 'upcoming' end;
        insert into matches (ext_id, home, away, competition, kickoff, status, home_score, away_score, home_logo, away_logo)
        values (s.code || ':' || (ev->>'id'),
                left(h->'team'->>'displayName', 40), left(a->'team'->>'displayName', 40), s.label,
                (ev->>'date')::timestamptz, st,
                case when st in ('live', 'finished') then nullif(h->>'score', '')::int end,
                case when st in ('live', 'finished') then nullif(a->>'score', '')::int end,
                h->'team'->>'logo', a->'team'->>'logo')
        on conflict (ext_id) do update set
          home = excluded.home, away = excluded.away, kickoff = excluded.kickoff, status = excluded.status,
          home_score = excluded.home_score, away_score = excluded.away_score,
          home_logo = excluded.home_logo, away_logo = excluded.away_logo;
        n := n + 1;
      end loop;
    exception when others then
      bad := bad || s.code || ' ';
      if why = '' then why := s.code || ' error: ' || left(sqlerrm, 160); end if;
    end;
  end loop;
  update match_sync set last_at = now(), last_note = n || ' matches' || case when bad <> '' then ', skipped: ' || bad || ' | ' || why else '' end where id = 1;
  return n || ' matches' || case when bad <> '' then ', skipped: ' || bad || ' | Reason: ' || why else '' end;
end $$;

-- Anyone opening Match day can ask for fresh scores: one competition per call, at most every 30 seconds
-- (live games first), so it never makes the page slow
create or replace function refresh_matches() returns void
language plpgsql security definer set search_path = public as $$
begin
  if (select coalesce(last_at, 'epoch') from match_sync where id = 1) > now() - interval '30 seconds' then return; end if;
  update match_sync set last_at = now() where id = 1;
  perform sync_matches(1);
end $$;

-- Admin: run it now and see what happened
create or replace function admin_sync_matches() returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return sync_matches(4);
end $$;

revoke execute on function sync_matches(int) from public, anon, authenticated;
revoke execute on function refresh_matches(), admin_sync_matches() from public;
grant execute on function refresh_matches() to anon, authenticated;
grant execute on function admin_sync_matches() to authenticated;

-- Every 5 minutes, automatically (needs the pg_cron extension, which Supabase has)
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('sync-matches') where exists (select 1 from cron.job where jobname = 'sync-matches');
  perform cron.schedule('sync-matches', '*/5 * * * *', 'select public.sync_matches(100)');
exception when others then
  raise notice 'Auto timer not set up (%). Scores will still update when people open Match day.', sqlerrm;
end $$;

select sync_matches(100) as first_sync;
notify pgrst, 'reload schema';
