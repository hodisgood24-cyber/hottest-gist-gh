-- Hottest Gist GH: two-player games between friends (Penalty shootout first).
-- Run AFTER setup-friends.sql and setup-messages.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

create table if not exists game_rooms (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('penalty')),
  p1 uuid not null,                 -- the player who invited
  p2 uuid not null,
  status text not null default 'invited' check (status in ('invited', 'active', 'done', 'declined')),
  round int not null default 1,
  pick1 int,                        -- secret choice of p1 this round (0 left, 1 centre, 2 right)
  pick2 int,
  score1 int not null default 0,
  score2 int not null default 0,
  history jsonb not null default '[]'::jsonb,
  winner uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (p1 <> p2)
);
create index if not exists game_rooms_p1 on game_rooms (p1, status);
create index if not exists game_rooms_p2 on game_rooms (p2, status);
alter table game_rooms enable row level security;
revoke all on game_rooms from anon, authenticated;   -- everything goes through the functions below so secret picks stay secret

-- What the browser sees (never the opponent's secret pick)
create or replace function game_view(r game_rooms) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', r.id, 'kind', r.kind, 'status', r.status, 'round', r.round,
    'p1', r.p1, 'p2', r.p2, 'score1', r.score1, 'score2', r.score2,
    'history', r.history, 'winner', r.winner, 'updated_at', r.updated_at,
    'mine', case when auth.uid() = r.p1 then 1 else 2 end,
    'my_pick', case when auth.uid() = r.p1 then r.pick1 else r.pick2 end,
    'opp_picked', case when auth.uid() = r.p1 then r.pick2 is not null else r.pick1 is not null end,
    'p1_name', (select name from profiles where user_id = r.p1), 'p1_avatar', (select avatar from profiles where user_id = r.p1),
    'p2_name', (select name from profiles where user_id = r.p2), 'p2_avatar', (select avatar from profiles where user_id = r.p2)
  )
$$;
revoke execute on function game_view(game_rooms) from public, anon, authenticated;

-- Challenge a friend (they also get a chat message)
create or replace function game_invite(p_to uuid, p_kind text default 'penalty') returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); nid bigint; nm text;
begin
  if me is null then raise exception 'login required'; end if;
  if p_kind <> 'penalty' then raise exception 'unknown game'; end if;
  if not exists (select 1 from friendships f where f.a = least(me, p_to) and f.b = greatest(me, p_to) and f.status = 'accepted') then
    raise exception 'You can only challenge your friends';
  end if;
  select id into nid from game_rooms where status in ('invited', 'active') and kind = p_kind
    and ((p1 = me and p2 = p_to) or (p1 = p_to and p2 = me)) order by id desc limit 1;
  if nid is not null then return nid; end if;
  if (select count(*) from game_rooms where p1 = me and created_at > now() - interval '1 hour') >= 10 then raise exception 'Slow down a little'; end if;
  insert into game_rooms (kind, p1, p2) values (p_kind, me, p_to) returning id into nid;
  select name into nm from profiles where user_id = me;
  insert into messages (sender, recipient, body) values (me, p_to, '⚽ ' || coalesce(nm, 'A friend') || ' challenged you to a Penalty Shootout! Open Play to accept.');
  return nid;
end $$;

create or replace function game_respond(p_id bigint, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r game_rooms;
begin
  select * into r from game_rooms where id = p_id for update;
  if r.id is null or r.p2 <> me or r.status <> 'invited' then raise exception 'not allowed'; end if;
  update game_rooms set status = case when p_accept then 'active' else 'declined' end, updated_at = now() where id = p_id returning * into r;
  return game_view(r);
end $$;

create or replace function game_state(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r game_rooms;
begin
  select * into r from game_rooms where id = p_id and auth.uid() in (p1, p2);
  if r.id is null then raise exception 'not found'; end if;
  return game_view(r);
end $$;

create or replace function game_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(game_view(r) order by r.updated_at desc), '[]'::jsonb)
  from (select * from game_rooms where auth.uid() in (p1, p2)
        and (status in ('invited', 'active') or updated_at > now() - interval '2 days') and status <> 'declined'
        order by updated_at desc limit 30) r
$$;

-- Choose where to shoot (or dive). When both players have chosen, the kick is decided.
create or replace function game_move(p_id bigint, p_dir int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r game_rooms; shooter int; shot int; dive int; goal boolean; s1 int; s2 int; done boolean := false; win uuid; left1 int; left2 int;
begin
  if p_dir not in (0, 1, 2) then raise exception 'bad move'; end if;
  select * into r from game_rooms where id = p_id for update;
  if r.id is null or me not in (r.p1, r.p2) or r.status <> 'active' then raise exception 'not allowed'; end if;
  if me = r.p1 then
    if r.pick1 is not null then return game_view(r); end if;
    update game_rooms set pick1 = p_dir, updated_at = now() where id = p_id returning * into r;
  else
    if r.pick2 is not null then return game_view(r); end if;
    update game_rooms set pick2 = p_dir, updated_at = now() where id = p_id returning * into r;
  end if;
  if r.pick1 is not null and r.pick2 is not null then
    shooter := case when r.round % 2 = 1 then 1 else 2 end;
    shot := case when shooter = 1 then r.pick1 else r.pick2 end;
    dive := case when shooter = 1 then r.pick2 else r.pick1 end;
    goal := shot <> dive;
    s1 := r.score1 + case when goal and shooter = 1 then 1 else 0 end;
    s2 := r.score2 + case when goal and shooter = 2 then 1 else 0 end;
    if r.round >= 10 and r.round % 2 = 0 and s1 <> s2 then done := true; win := case when s1 > s2 then r.p1 else r.p2 end; end if;
    if r.round >= 20 and not done then done := true; win := case when s1 > s2 then r.p1 when s2 > s1 then r.p2 else null end; end if;
    -- early finish: one side can no longer catch up within the first 10 kicks
    if not done and r.round < 10 then
      left1 := 5 - (r.round + 1) / 2;   -- kicks p1 still has (odd rounds left)
      left2 := 5 - r.round / 2;         -- kicks p2 still has (even rounds left)
      if s1 > s2 + left2 then done := true; win := r.p1;
      elsif s2 > s1 + left1 then done := true; win := r.p2; end if;
    end if;
    update game_rooms set
      history = history || jsonb_build_array(jsonb_build_object('round', r.round, 'shooter', shooter, 'shot', shot, 'dive', dive, 'goal', goal)),
      score1 = s1, score2 = s2, pick1 = null, pick2 = null, round = r.round + 1,
      status = case when done then 'done' else 'active' end, winner = win, updated_at = now()
    where id = p_id returning * into r;
  end if;
  return game_view(r);
end $$;

-- Give up, or claim the win when the other player has been silent for 3 minutes
create or replace function game_end(p_id bigint, p_how text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r game_rooms; other uuid;
begin
  select * into r from game_rooms where id = p_id for update;
  if r.id is null or me not in (r.p1, r.p2) or r.status not in ('active', 'invited') then raise exception 'not allowed'; end if;
  other := case when me = r.p1 then r.p2 else r.p1 end;
  if p_how = 'resign' then
    update game_rooms set status = case when r.status = 'invited' then 'declined' else 'done' end, winner = case when r.status = 'invited' then null else other end, updated_at = now() where id = p_id returning * into r;
  elsif p_how = 'claim' then
    if r.status <> 'active' or r.updated_at > now() - interval '3 minutes' then raise exception 'too soon'; end if;
    if not ((me = r.p1 and r.pick1 is not null and r.pick2 is null) or (me = r.p2 and r.pick2 is not null and r.pick1 is null)) then raise exception 'not allowed'; end if;
    update game_rooms set status = 'done', winner = me, updated_at = now() where id = p_id returning * into r;
  else raise exception 'bad request'; end if;
  return game_view(r);
end $$;

revoke execute on function game_invite(uuid, text), game_respond(bigint, boolean), game_state(bigint), game_list(), game_move(bigint, int), game_end(bigint, text) from public, anon;
grant execute on function game_invite(uuid, text), game_respond(bigint, boolean), game_state(bigint), game_list(), game_move(bigint, int), game_end(bigint, text) to authenticated;

notify pgrst, 'reload schema';
