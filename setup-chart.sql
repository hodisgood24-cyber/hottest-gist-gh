-- Hottest Gist GH: weekly Ghana Top 10 that fans build and vote on.
-- Fans add songs and vote for one song each week (they can change their vote). New chart every Monday.
-- Run AFTER setup-owner.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

create or replace function chart_week(t timestamptz default now()) returns text
language sql stable as $$ select to_char(t at time zone 'Africa/Accra', 'IYYY-IW') $$;

create table if not exists chart_songs (
  id bigint generated always as identity primary key,
  week text not null,
  title text not null,
  artist text not null,
  added_by uuid,
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index if not exists chart_songs_uniq on chart_songs (week, lower(title), lower(artist));
alter table chart_songs enable row level security;
revoke all on chart_songs from anon, authenticated;

create table if not exists chart_votes (
  week text not null,
  client_id uuid not null,
  song_id bigint not null references chart_songs (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (week, client_id)
);
alter table chart_votes enable row level security;
drop policy if exists "own chart votes" on chart_votes;
create policy "own chart votes" on chart_votes for select to authenticated using (client_id = auth.uid());
revoke all on chart_votes from anon, authenticated;
grant select on chart_votes to authenticated;

-- This week's chart and last week's results (everyone can read)
create or replace view chart_now as
  select s.id, s.week, s.title, s.artist, count(v.client_id)::int as votes, s.created_at
  from chart_songs s left join chart_votes v on v.song_id = s.id
  where not s.hidden and s.week in (chart_week(), chart_week(now() - interval '7 days'))
  group by s.id;
grant select on chart_now to anon, authenticated;

create or replace function add_chart_song(p_title text, p_artist text) returns bigint
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); w text := chart_week(); t text := left(trim(p_title), 80); a text := left(trim(p_artist), 60); sid bigint;
begin
  if u is null then raise exception 'login required'; end if;
  if t = '' or a = '' then raise exception 'song and artist needed'; end if;
  select id into sid from chart_songs where week = w and lower(title) = lower(t) and lower(artist) = lower(a);
  if sid is null then
    if (select count(*) from chart_songs where week = w and added_by = u) >= 3 then raise exception 'You can add 3 songs a week'; end if;
    insert into chart_songs (week, title, artist, added_by, hidden)
    values (w, t, a, u, (t || ' ' || a) ~* '(https?://|www\.)' or exists (select 1 from blocked_words b where (t || ' ' || a) ~* ('\m' || b.word || '\M')))
    returning id into sid;
  end if;
  insert into chart_votes (week, client_id, song_id) values (w, u, sid)
  on conflict (week, client_id) do update set song_id = excluded.song_id, created_at = now();
  return sid;
end $$;

create or replace function vote_chart(p_song bigint) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); w text := chart_week();
begin
  if u is null then raise exception 'login required'; end if;
  if not exists (select 1 from chart_songs where id = p_song and week = w and not hidden) then raise exception 'voting closed'; end if;
  insert into chart_votes (week, client_id, song_id) values (w, u, p_song)
  on conflict (week, client_id) do update set song_id = excluded.song_id, created_at = now();
end $$;

create or replace function admin_hide_chart_song(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  update chart_songs set hidden = true where id = p_id;
end $$;

revoke execute on function add_chart_song(text, text) from public, anon;
revoke execute on function vote_chart(bigint) from public, anon;
revoke execute on function admin_hide_chart_song(bigint) from public, anon;
grant execute on function add_chart_song(text, text) to authenticated;
grant execute on function vote_chart(bigint) to authenticated;
grant execute on function admin_hide_chart_song(bigint) to authenticated;
