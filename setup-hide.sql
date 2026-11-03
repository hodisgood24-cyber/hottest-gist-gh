-- Hottest Gist GH: Hide and Seek (two players, friends only).
-- Run AFTER setup-friends.sql and setup-messages.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.
-- 6 rounds. Odd rounds p1 hides, even rounds p2 hides. 9 hiding spots (0-8, a 3x3 yard).
-- The seeker gets 3 tries per round. Found on try 1/2/3 = 3/2/1 points to the seeker. Not found = 2 points to the hider.

create table if not exists hide_rooms (
  id bigint generated always as identity primary key,
  p1 uuid not null,
  p2 uuid not null,
  status text not null default 'invited' check (status in ('invited', 'active', 'done', 'declined')),
  round int not null default 1,
  spot int,                                   -- secret hiding spot this round (null until the hider hides)
  guesses jsonb not null default '[]'::jsonb, -- [{"g":4,"h":"hot"}] seeker's tries this round
  score1 int not null default 0,
  score2 int not null default 0,
  history jsonb not null default '[]'::jsonb, -- [{"round":1,"hider":1,"spot":4,"found":true,"tries":2}]
  winner uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (p1 <> p2)
);
create index if not exists hide_rooms_p1 on hide_rooms (p1, status);
create index if not exists hide_rooms_p2 on hide_rooms (p2, status);
alter table hide_rooms enable row level security;
revoke all on hide_rooms from anon, authenticated;

create or replace function hide_view(r hide_rooms) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', r.id, 'kind', 'hide', 'status', r.status, 'round', r.round,
    'p1', r.p1, 'p2', r.p2, 'score1', r.score1, 'score2', r.score2,
    'history', r.history, 'winner', r.winner, 'updated_at', r.updated_at,
    'mine', case when auth.uid() = r.p1 then 1 else 2 end,
    'hider', case when r.round % 2 = 1 then 1 else 2 end,
    'hidden', r.spot is not null,
    'my_spot', case when r.spot is not null and ((r.round % 2 = 1 and auth.uid() = r.p1) or (r.round % 2 = 0 and auth.uid() = r.p2)) then r.spot else null end,
    'guesses', r.guesses,
    'p1_name', (select name from profiles where user_id = r.p1), 'p1_avatar', (select avatar from profiles where user_id = r.p1),
    'p2_name', (select name from profiles where user_id = r.p2), 'p2_avatar', (select avatar from profiles where user_id = r.p2)
  )
$$;
revoke execute on function hide_view(hide_rooms) from public, anon, authenticated;

create or replace function hide_invite(p_to uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); nid bigint; nm text;
begin
  if me is null then raise exception 'login required'; end if;
  if not exists (select 1 from friendships f where f.a = least(me, p_to) and f.b = greatest(me, p_to) and f.status = 'accepted') then
    raise exception 'You can only challenge your friends';
  end if;
  select id into nid from hide_rooms where status in ('invited', 'active')
    and ((p1 = me and p2 = p_to) or (p1 = p_to and p2 = me)) order by id desc limit 1;
  if nid is not null then return nid; end if;
  if (select count(*) from hide_rooms where p1 = me and created_at > now() - interval '1 hour') >= 10 then raise exception 'Slow down a little'; end if;
  insert into hide_rooms (p1, p2) values (me, p_to) returning id into nid;
  select name into nm from profiles where user_id = me;
  insert into messages (sender, recipient, body) values (me, p_to, '🙈 ' || coalesce(nm, 'A friend') || ' wants to play Hide and Seek! Open Play to accept.');
  return nid;
end $$;

create or replace function hide_respond(p_id bigint, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r hide_rooms;
begin
  select * into r from hide_rooms where id = p_id for update;
  if r.id is null or r.p2 <> me or r.status <> 'invited' then raise exception 'not allowed'; end if;
  update hide_rooms set status = case when p_accept then 'active' else 'declined' end, updated_at = now() where id = p_id returning * into r;
  return hide_view(r);
end $$;

create or replace function hide_state(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r hide_rooms;
begin
  select * into r from hide_rooms where id = p_id and auth.uid() in (p1, p2);
  if r.id is null then raise exception 'not found'; end if;
  return hide_view(r);
end $$;

create or replace function hide_list() returns setof jsonb
language sql stable security definer set search_path = public as $$
  select hide_view(r) from (select * from hide_rooms where auth.uid() in (p1, p2)
    and (status in ('invited', 'active') or updated_at > now() - interval '2 days') and status <> 'declined'
    order by updated_at desc limit 30) r
$$;

-- The hider picks a hiding spot
create or replace function hide_hide(p_id bigint, p_spot int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r hide_rooms; hider uuid;
begin
  if p_spot < 0 or p_spot > 8 then raise exception 'bad spot'; end if;
  select * into r from hide_rooms where id = p_id for update;
  if r.id is null or me not in (r.p1, r.p2) or r.status <> 'active' then raise exception 'not allowed'; end if;
  hider := case when r.round % 2 = 1 then r.p1 else r.p2 end;
  if me <> hider then raise exception 'You are the seeker this round'; end if;
  if r.spot is not null then return hide_view(r); end if;
  update hide_rooms set spot = p_spot, guesses = '[]'::jsonb, updated_at = now() where id = p_id returning * into r;
  return hide_view(r);
end $$;

-- The seeker tries a spot
create or replace function hide_seek(p_id bigint, p_spot int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r hide_rooms; hider uuid; seeker uuid; n int; found boolean; hint text; dx int; dy int;
        pts_s int := 0; pts_h int := 0; round_over boolean := false; hi int; fin boolean := false; win uuid;
begin
  if p_spot < 0 or p_spot > 8 then raise exception 'bad spot'; end if;
  select * into r from hide_rooms where id = p_id for update;
  if r.id is null or me not in (r.p1, r.p2) or r.status <> 'active' then raise exception 'not allowed'; end if;
  hider := case when r.round % 2 = 1 then r.p1 else r.p2 end;
  seeker := case when hider = r.p1 then r.p2 else r.p1 end;
  if me <> seeker then raise exception 'You are the hider this round'; end if;
  if r.spot is null then raise exception 'Wait for them to hide'; end if;
  n := jsonb_array_length(r.guesses);
  if n >= 3 then return hide_view(r); end if;
  if exists (select 1 from jsonb_array_elements(r.guesses) e where (e->>'g')::int = p_spot) then raise exception 'You already looked there'; end if;
  found := (p_spot = r.spot);
  dx := abs(p_spot % 3 - r.spot % 3); dy := abs(p_spot / 3 - r.spot / 3);
  hint := case when found then 'found' when greatest(dx, dy) = 1 then 'hot' else 'cold' end;
  n := n + 1;
  r.guesses := r.guesses || jsonb_build_array(jsonb_build_object('g', p_spot, 'h', hint));
  if found then pts_s := 4 - n; round_over := true;
  elsif n >= 3 then pts_h := 2; round_over := true; end if;
  if not round_over then
    update hide_rooms set guesses = r.guesses, updated_at = now() where id = p_id returning * into r;
    return hide_view(r);
  end if;
  -- round finished: record it, swap roles
  hi := case when hider = r.p1 then 1 else 2 end;
  update hide_rooms set
    history = history || jsonb_build_array(jsonb_build_object('round', round, 'hider', hi, 'spot', r.spot, 'found', found, 'tries', n, 'guesses', r.guesses)),
    score1 = score1 + case when seeker = p1 then pts_s else pts_h end,
    score2 = score2 + case when seeker = p2 then pts_s else pts_h end,
    spot = null, guesses = '[]'::jsonb, round = round + 1, updated_at = now()
  where id = p_id returning * into r;
  if r.round > 6 then
    win := case when r.score1 > r.score2 then r.p1 when r.score2 > r.score1 then r.p2 else null end;
    update hide_rooms set status = 'done', winner = win where id = p_id returning * into r;
  end if;
  return hide_view(r);
end $$;

-- Give up, or claim the win when the other player has been silent for 3 minutes on their turn
create or replace function hide_end(p_id bigint, p_how text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r hide_rooms; other uuid; hider uuid; seeker uuid; on_turn uuid;
begin
  select * into r from hide_rooms where id = p_id for update;
  if r.id is null or me not in (r.p1, r.p2) or r.status not in ('active', 'invited') then raise exception 'not allowed'; end if;
  other := case when me = r.p1 then r.p2 else r.p1 end;
  if p_how = 'resign' then
    update hide_rooms set status = case when r.status = 'invited' then 'declined' else 'done' end, winner = case when r.status = 'invited' then null else other end, updated_at = now() where id = p_id returning * into r;
  elsif p_how = 'claim' then
    if r.status <> 'active' or r.updated_at > now() - interval '3 minutes' then raise exception 'too soon'; end if;
    hider := case when r.round % 2 = 1 then r.p1 else r.p2 end;
    seeker := case when hider = r.p1 then r.p2 else r.p1 end;
    on_turn := case when r.spot is null then hider else seeker end;
    if on_turn = me then raise exception 'not allowed'; end if;
    update hide_rooms set status = 'done', winner = me, updated_at = now() where id = p_id returning * into r;
  else raise exception 'bad request'; end if;
  return hide_view(r);
end $$;

revoke execute on function hide_invite(uuid), hide_respond(bigint, boolean), hide_state(bigint), hide_list(), hide_hide(bigint, int), hide_seek(bigint, int), hide_end(bigint, text) from public, anon;
grant execute on function hide_invite(uuid), hide_respond(bigint, boolean), hide_state(bigint), hide_list(), hide_hide(bigint, int), hide_seek(bigint, int), hide_end(bigint, text) to authenticated;

notify pgrst, 'reload schema';
