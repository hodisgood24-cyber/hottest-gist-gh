-- Daily streaks and points. Run once in Supabase SQL Editor.
create table if not exists daily_checkins (
  user_id uuid not null,
  day date not null,
  pts int not null,
  streak int not null,
  primary key (user_id, day)
);
alter table daily_checkins enable row level security;
revoke all on daily_checkins from anon, authenticated;

-- Claim today's check-in (Ghana date = UTC). Safe to call many times a day.
create or replace function daily_checkin() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); today date := (now() at time zone 'utc')::date;
  prev int; s int; p int; claimed boolean := false; total int; best int;
begin
  if me is null then raise exception 'login required'; end if;
  select streak into s from daily_checkins where user_id = me and day = today;
  if s is null then
    select streak into prev from daily_checkins where user_id = me and day = today - 1;
    s := coalesce(prev, 0) + 1;
    p := least(5 + (s - 1) * 2, 25) + case when s % 7 = 0 then 50 else 0 end;
    insert into daily_checkins(user_id, day, pts, streak) values (me, today, p, s);
    claimed := true;
  else
    select pts into p from daily_checkins where user_id = me and day = today;
  end if;
  select coalesce(sum(pts), 0), coalesce(max(streak), 0) into total, best from daily_checkins where user_id = me;
  return jsonb_build_object('streak', s, 'today', p, 'claimed', claimed, 'points', total, 'best', best);
end $$;

-- Read only: current streak and points without claiming.
create or replace function my_streak() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); today date := (now() at time zone 'utc')::date; s int; total int; best int; done boolean;
begin
  if me is null then raise exception 'login required'; end if;
  select streak into s from daily_checkins where user_id = me and day = today;
  done := s is not null;
  if s is null then select streak into s from daily_checkins where user_id = me and day = today - 1; end if;
  select coalesce(sum(pts), 0), coalesce(max(streak), 0) into total, best from daily_checkins where user_id = me;
  return jsonb_build_object('streak', coalesce(s, 0), 'done', done, 'points', total, 'best', best);
end $$;

-- Leaderboard of top fans by points.
create or replace function streak_top() returns table (user_id uuid, name text, avatar text, verified boolean, points bigint, streak int)
language sql stable security definer set search_path = public as $$
  select c.user_id, p.name, p.avatar, p.verified, c.points, coalesce(
    (select d.streak from daily_checkins d where d.user_id = c.user_id and d.day >= (now() at time zone 'utc')::date - 1 order by d.day desc limit 1), 0)
  from (select user_id, sum(pts) as points from daily_checkins group by user_id order by sum(pts) desc limit 20) c
  join profiles p on p.user_id = c.user_id
  order by c.points desc;
$$;

grant execute on function daily_checkin() to authenticated;
grant execute on function my_streak() to authenticated;
grant execute on function streak_top() to anon, authenticated;
