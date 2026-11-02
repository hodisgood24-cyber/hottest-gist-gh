-- Hottest Gist GH: reactions, polls, fan wall, replies, badges.
-- Paste all of this into Supabase > SQL Editor > Run. Safe to run again.

-- ===== Emoji reactions =====
create table if not exists reactions (
  post_id text not null,
  client_id text not null,
  emoji text not null,
  primary key (post_id, client_id, emoji)
);
alter table reactions enable row level security;
drop policy if exists "own reactions" on reactions;
create policy "own reactions" on reactions for select to authenticated using (client_id = auth.uid()::text);
revoke all on reactions from anon, authenticated;
grant select on reactions to authenticated;

create or replace view reaction_counts as
  select post_id, emoji, count(*)::int as n from reactions group by post_id, emoji;
grant select on reaction_counts to authenticated;

create or replace function toggle_reaction_auth(p_post text, p_emoji text, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare u text := auth.uid()::text;
begin
  if u is null then raise exception 'login required'; end if;
  if p_emoji not in ('fire','lol','love','clap') or length(p_post) > 100 then raise exception 'bad input'; end if;
  if p_on then
    insert into reactions (post_id, client_id, emoji) values (p_post, u, p_emoji) on conflict do nothing;
  else
    delete from reactions where post_id = p_post and client_id = u and emoji = p_emoji;
  end if;
end $$;
revoke execute on function toggle_reaction_auth(text, text, boolean) from public, anon;
grant execute on function toggle_reaction_auth(text, text, boolean) to authenticated;

-- ===== Polls =====
create table if not exists poll_votes (
  poll_id text not null,
  client_id text not null,
  option_idx int not null,
  primary key (poll_id, client_id)
);
alter table poll_votes enable row level security;
drop policy if exists "own votes" on poll_votes;
create policy "own votes" on poll_votes for select to authenticated using (client_id = auth.uid()::text);
revoke all on poll_votes from anon, authenticated;
grant select on poll_votes to authenticated;

create or replace view poll_counts as
  select poll_id, option_idx, count(*)::int as n from poll_votes group by poll_id, option_idx;
grant select on poll_counts to authenticated;

create or replace function vote_poll_auth(p_poll text, p_opt int)
returns void language plpgsql security definer set search_path = public as $$
declare u text := auth.uid()::text;
begin
  if u is null then raise exception 'login required'; end if;
  if length(p_poll) > 100 or p_opt < 0 or p_opt > 19 then raise exception 'bad input'; end if;
  insert into poll_votes (poll_id, client_id, option_idx) values (p_poll, u, p_opt)
  on conflict (poll_id, client_id) do update set option_idx = excluded.option_idx;
end $$;
revoke execute on function vote_poll_auth(text, int) from public, anon;
grant execute on function vote_poll_auth(text, int) to authenticated;

-- ===== Fan wall =====
create table if not exists wall (
  id bigint generated always as identity primary key,
  client_id text not null,
  name text not null,
  text text not null,
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);
alter table wall enable row level security;
drop policy if exists "read wall" on wall;
create policy "read wall" on wall for select to authenticated using (hidden = false);
revoke all on wall from anon, authenticated;
grant select on wall to authenticated;

create or replace function post_wall_auth(p_text text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare u text := auth.uid()::text; n text;
begin
  if u is null then raise exception 'login required'; end if;
  if length(trim(p_text)) < 1 or length(p_text) > 200 then raise exception 'bad message'; end if;
  if (select count(*) from wall where client_id = u and created_at > now() - interval '1 minute') >= 2 then
    raise exception 'slow down';
  end if;
  select left(coalesce(nullif(trim(raw_user_meta_data->>'name'), ''), nullif(trim(raw_user_meta_data->>'full_name'), ''), 'Fan'), 40)
    into n from auth.users where id = auth.uid();
  insert into wall (client_id, name, text) values (u, coalesce(n, 'Fan'), trim(p_text));
end $$;
revoke execute on function post_wall_auth(text) from public, anon;
grant execute on function post_wall_auth(text) to authenticated;

-- ===== Replies to comments =====
alter table comments add column if not exists parent_id bigint;
drop function if exists add_comment_auth(text, text);
create or replace function add_comment_auth(p_post text, p_text text, p_parent bigint default null)
returns void language plpgsql security definer set search_path = public, auth as $$
declare u text := auth.uid()::text; n text;
begin
  if u is null then raise exception 'login required'; end if;
  if length(trim(p_text)) < 1 or length(p_text) > 500 or length(p_post) > 100 then raise exception 'bad comment'; end if;
  if p_parent is not null and not exists (select 1 from comments where id = p_parent and post_id = p_post and hidden = false) then
    raise exception 'bad parent';
  end if;
  if (select count(*) from comments where client_id = u and created_at > now() - interval '1 minute') >= 3 then
    raise exception 'slow down';
  end if;
  select left(coalesce(nullif(trim(raw_user_meta_data->>'name'), ''), nullif(trim(raw_user_meta_data->>'full_name'), ''), 'Fan'), 40)
    into n from auth.users where id = auth.uid();
  insert into comments (post_id, client_id, name, text, parent_id) values (p_post, u, coalesce(n, 'Fan'), trim(p_text), p_parent);
end $$;
revoke execute on function add_comment_auth(text, text, bigint) from public, anon;
grant execute on function add_comment_auth(text, text, bigint) to authenticated;

-- ===== Badges =====
create or replace view user_stats as
  select coalesce(c.client_id, l.client_id) as client_id,
         coalesce(c.n, 0)::int as comments,
         coalesce(l.n, 0)::int as likes
  from (select client_id, count(*) as n from comments where hidden = false group by client_id) c
  full join (select client_id, count(*) as n from likes group by client_id) l on c.client_id = l.client_id;
grant select on user_stats to authenticated;

notify pgrst, 'reload schema';
