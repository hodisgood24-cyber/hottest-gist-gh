-- Hottest Gist GH: Match day — score predictions, live match chat and a predictors leaderboard.
-- Run AFTER setup-owner.sql and setup-creators.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

create table if not exists matches (
  id bigint generated always as identity primary key,
  home text not null,
  away text not null,
  competition text not null default 'Black Stars',
  kickoff timestamptz not null,
  status text not null default 'upcoming' check (status in ('upcoming', 'live', 'finished', 'postponed')),
  home_score int,
  away_score int,
  created_at timestamptz not null default now()
);
create index if not exists matches_kickoff on matches (kickoff desc);
alter table matches enable row level security;
drop policy if exists "read matches" on matches;
create policy "read matches" on matches for select to anon, authenticated using (true);
revoke all on matches from anon, authenticated;
grant select on matches to anon, authenticated;

create table if not exists predictions (
  match_id bigint not null references matches (id) on delete cascade,
  user_id uuid not null,
  home int not null check (home between 0 and 20),
  away int not null check (away between 0 and 20),
  created_at timestamptz not null default now(),
  primary key (match_id, user_id)
);
alter table predictions enable row level security;
drop policy if exists "own predictions" on predictions;
create policy "own predictions" on predictions for select to authenticated using (user_id = auth.uid());
revoke all on predictions from anon, authenticated;
grant select on predictions to authenticated;

create table if not exists match_chat (
  id bigint generated always as identity primary key,
  match_id bigint not null references matches (id) on delete cascade,
  user_id uuid not null,
  name text not null,
  body text not null check (length(body) between 1 and 300),
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists match_chat_match on match_chat (match_id, id);
alter table match_chat enable row level security;
drop policy if exists "read match chat" on match_chat;
create policy "read match chat" on match_chat for select to anon, authenticated using (not hidden);
revoke all on match_chat from anon, authenticated;
grant select on match_chat to anon, authenticated;

-- How many fans predicted each match, and what they think
create or replace view match_pred_stats as
  select match_id, count(*)::int as n,
         count(*) filter (where home > away)::int as home_win,
         count(*) filter (where home = away)::int as draw,
         count(*) filter (where home < away)::int as away_win
  from predictions group by match_id;
grant select on match_pred_stats to anon, authenticated;

-- Points: exact score = 3, right result = 1
create or replace function pred_points(ph int, pa int, rh int, ra int) returns int
language sql immutable as $$
  select case when rh is null or ra is null then 0
              when ph = rh and pa = ra then 3
              when sign(ph - pa) = sign(rh - ra) then 1 else 0 end
$$;

create or replace view predictor_board as
  select p.user_id, coalesce(pr.name, 'Fan') as name, pr.avatar,
         sum(pred_points(p.home, p.away, m.home_score, m.away_score))::int as points,
         count(*) filter (where p.home = m.home_score and p.away = m.away_score)::int as exact,
         count(*)::int as played,
         to_char(m.kickoff at time zone 'Africa/Accra', 'YYYY-MM') as month
  from predictions p
  join matches m on m.id = p.match_id and m.status = 'finished'
  left join profiles pr on pr.user_id = p.user_id
  group by p.user_id, pr.name, pr.avatar, to_char(m.kickoff at time zone 'Africa/Accra', 'YYYY-MM');
grant select on predictor_board to anon, authenticated;

-- Predict (until kick-off)
create or replace function predict_match(p_match bigint, p_home int, p_away int) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); m matches;
begin
  if u is null then raise exception 'login required'; end if;
  select * into m from matches where id = p_match;
  if m.id is null then raise exception 'match not found'; end if;
  if m.status <> 'upcoming' or now() >= m.kickoff then raise exception 'Predictions are closed for this match'; end if;
  if p_home not between 0 and 20 or p_away not between 0 and 20 then raise exception 'bad score'; end if;
  insert into predictions (match_id, user_id, home, away) values (p_match, u, p_home, p_away)
  on conflict (match_id, user_id) do update set home = excluded.home, away = excluded.away, created_at = now();
end $$;

-- Live chat (from 2 hours before kick-off until 4 hours after)
create or replace function match_say(p_match bigint, p_body text) returns bigint
language plpgsql security definer set search_path = public, auth as $$
declare u uuid := auth.uid(); m matches; b text := trim(coalesce(p_body, '')); n text; nid bigint;
begin
  if u is null then raise exception 'login required'; end if;
  select * into m from matches where id = p_match;
  if m.id is null then raise exception 'match not found'; end if;
  if now() < m.kickoff - interval '2 hours' then raise exception 'The chat opens 2 hours before kick-off'; end if;
  if now() > m.kickoff + interval '4 hours' then raise exception 'The chat for this match is closed'; end if;
  if b = '' or length(b) > 300 then raise exception 'Messages can be up to 300 characters'; end if;
  if (select count(*) from match_chat where user_id = u and created_at > now() - interval '30 seconds') >= 5 then raise exception 'Slow down a little'; end if;
  select coalesce(p.name, left(coalesce(nullif(trim(x.raw_user_meta_data->>'name'), ''), 'Fan'), 40)) into n
    from auth.users x left join profiles p on p.user_id = x.id where x.id = u;
  insert into match_chat (match_id, user_id, name, body, hidden)
  values (p_match, u, coalesce(n, 'Fan'), b,
          b ~* '(https?://|www\.)' or exists (select 1 from blocked_words w where b ~* ('\m' || w.word || '\M')))
  returning id into nid;
  return nid;
end $$;

-- Admin: add, update and remove matches; hide chat messages
create or replace function admin_save_match(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare mid bigint := nullif(p->>'id', '')::bigint;
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if mid is null then
    insert into matches (home, away, competition, kickoff, status)
    values (p->>'home', p->>'away', coalesce(nullif(p->>'competition', ''), 'Black Stars'), (p->>'kickoff')::timestamptz, coalesce(p->>'status', 'upcoming'))
    returning id into mid;
  else
    update matches set home = coalesce(p->>'home', home), away = coalesce(p->>'away', away),
      competition = coalesce(nullif(p->>'competition', ''), competition), kickoff = coalesce((p->>'kickoff')::timestamptz, kickoff),
      status = coalesce(p->>'status', status),
      home_score = case when p ? 'home_score' then nullif(p->>'home_score', '')::int else home_score end,
      away_score = case when p ? 'away_score' then nullif(p->>'away_score', '')::int else away_score end
    where id = mid;
  end if;
  return mid;
end $$;
create or replace function admin_delete_match(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  delete from matches where id = p_id;
end $$;
create or replace function admin_hide_chat(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  update match_chat set hidden = true where id = p_id;
end $$;

revoke execute on function predict_match(bigint, int, int), match_say(bigint, text), admin_save_match(jsonb), admin_delete_match(bigint), admin_hide_chat(bigint) from public, anon;
grant execute on function predict_match(bigint, int, int), match_say(bigint, text), admin_save_match(jsonb), admin_delete_match(bigint), admin_hide_chat(bigint) to authenticated;
notify pgrst, 'reload schema';
