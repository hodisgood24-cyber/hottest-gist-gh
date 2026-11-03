-- Hottest Gist GH: bring in real matches automatically (fixtures, live scores and results).
-- Run AFTER setup-matchday.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.
-- Matches come from ESPN's public scoreboard feed. Scores update every 5 minutes,
-- and also whenever someone opens Match day (at most once every 2 minutes).

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
insert into match_sources (code, label, ghana_only) values
  ('fifa.friendly',     'Black Stars',            true),
  ('fifa.worldq.caf',   'World Cup qualifier',    true),
  ('caf.nations',       'AFCON',                  false),
  ('caf.nations_qual',  'AFCON qualifier',        true),
  ('gha.1',             'Ghana Premier League',   false),
  ('eng.1',             'Premier League',         false),
  ('uefa.champions',    'Champions League',       false)
on conflict (code) do nothing;
alter table match_sources enable row level security;
revoke all on match_sources from anon, authenticated;

create table if not exists match_sync (id int primary key default 1, last_at timestamptz, last_note text);
insert into match_sync (id) values (1) on conflict do nothing;
alter table match_sync enable row level security;
revoke all on match_sync from anon, authenticated;

-- Fetch the next 7 days (and yesterday) for every competition and save them
create or replace function sync_matches() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  s record; ev jsonb; c jsonb; h jsonb; a jsonb; st text; nm text; js jsonb; res record;
  d1 text := to_char((now() at time zone 'utc') - interval '1 day', 'YYYYMMDD');
  d2 text := to_char((now() at time zone 'utc') + interval '7 days', 'YYYYMMDD');
  n int := 0; bad text := '';
begin
  if not pg_try_advisory_xact_lock(424242) then return 'busy'; end if;
  perform http_set_curlopt('CURLOPT_TIMEOUT', '8');
  for s in select * from match_sources where enabled loop
    begin
      select * into res from http_get('https://site.api.espn.com/apis/site/v2/sports/soccer/' || s.code || '/scoreboard?limit=300&dates=' || d1 || '-' || d2);
      if res.status <> 200 then bad := bad || s.code || ' '; continue; end if;
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
    end;
  end loop;
  update match_sync set last_at = now(), last_note = n || ' matches' || case when bad <> '' then ', skipped: ' || bad else '' end where id = 1;
  return n || ' matches' || case when bad <> '' then ', skipped: ' || bad else '' end;
end $$;

-- Anyone opening Match day can ask for fresh scores (runs at most once every 2 minutes)
create or replace function refresh_matches() returns void
language plpgsql security definer set search_path = public as $$
begin
  if (select coalesce(last_at, 'epoch') from match_sync where id = 1) > now() - interval '2 minutes' then return; end if;
  update match_sync set last_at = now() where id = 1;
  perform sync_matches();
end $$;

-- Admin: run it now and see what happened
create or replace function admin_sync_matches() returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return sync_matches();
end $$;

revoke execute on function sync_matches() from public, anon, authenticated;
revoke execute on function refresh_matches(), admin_sync_matches() from public;
grant execute on function refresh_matches() to anon, authenticated;
grant execute on function admin_sync_matches() to authenticated;

-- Every 5 minutes, automatically (needs the pg_cron extension, which Supabase has)
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('sync-matches') where exists (select 1 from cron.job where jobname = 'sync-matches');
  perform cron.schedule('sync-matches', '*/5 * * * *', 'select public.sync_matches()');
exception when others then
  raise notice 'Auto timer not set up (%). Scores will still update when people open Match day.', sqlerrm;
end $$;

select sync_matches() as first_sync;
notify pgrst, 'reload schema';
