-- Hottest Gist GH: friends (send a friend request, accept or decline, see your friends).
-- Run AFTER setup-creators.sql and setup-notify.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

create table if not exists friendships (
  a uuid not null,              -- smaller user id of the pair
  b uuid not null,              -- larger user id of the pair
  requester uuid not null,      -- who sent the request
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  primary key (a, b),
  check (a < b)
);
create index if not exists friendships_b on friendships (b);
alter table friendships enable row level security;
revoke all on friendships from anon, authenticated;

-- Allow the new alert types in the notification bell
alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('like', 'comment', 'reply', 'follow', 'friend_request', 'friend_accept'));

-- Send a request (or accept straight away if they already asked you)
create or replace function friend_request(p_user uuid) returns text
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); x uuid; y uuid; f friendships;
begin
  if u is null then raise exception 'login required'; end if;
  if p_user is null or p_user = u then raise exception 'not allowed'; end if;
  if not exists (select 1 from profiles where user_id = p_user) then raise exception 'person not found'; end if;
  x := least(u, p_user); y := greatest(u, p_user);
  select * into f from friendships where a = x and b = y;
  if f.a is not null then
    if f.status = 'accepted' then return 'friends'; end if;
    if f.requester = u then return 'requested'; end if;
    update friendships set status = 'accepted', accepted_at = now() where a = x and b = y;
    begin perform add_note(p_user, u, 'friend_accept', null, ''); exception when others then null; end;
    return 'friends';
  end if;
  if (select count(*) from friendships where requester = u and created_at > now() - interval '1 hour') >= 40 then
    raise exception 'Too many requests. Try again later.';
  end if;
  insert into friendships (a, b, requester) values (x, y, u);
  begin perform add_note(p_user, u, 'friend_request', null, ''); exception when others then null; end;
  return 'requested';
end $$;

-- Accept or decline a request someone sent you
create or replace function friend_respond(p_user uuid, p_accept boolean) returns text
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); x uuid := least(u, p_user); y uuid := greatest(u, p_user);
begin
  if u is null then raise exception 'login required'; end if;
  if not exists (select 1 from friendships where a = x and b = y and status = 'pending' and requester = p_user) then return 'none'; end if;
  if p_accept then
    update friendships set status = 'accepted', accepted_at = now() where a = x and b = y;
    begin perform add_note(p_user, u, 'friend_accept', null, ''); exception when others then null; end;
    return 'friends';
  end if;
  delete from friendships where a = x and b = y;
  return 'none';
end $$;

-- Unfriend, or cancel a request you sent
create or replace function friend_remove(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'login required'; end if;
  delete from friendships where a = least(u, p_user) and b = greatest(u, p_user);
end $$;

-- My friends and requests, with names and photos
create or replace function my_friends()
returns table (user_id uuid, name text, avatar text, verified boolean, state text, since timestamptz)
language sql stable security definer set search_path = public as $$
  select o.uid, p.name, p.avatar,
         coalesce(p.verified and (p.verified_until is null or p.verified_until > now()), false),
         case when f.status = 'accepted' then 'friends' when f.requester = auth.uid() then 'sent' else 'incoming' end,
         coalesce(f.accepted_at, f.created_at)
  from friendships f
  cross join lateral (select case when f.a = auth.uid() then f.b else f.a end as uid) o
  join profiles p on p.user_id = o.uid
  where auth.uid() in (f.a, f.b)
  order by coalesce(f.accepted_at, f.created_at) desc
$$;

-- Find people by name
create or replace function find_people(p_q text)
returns table (user_id uuid, name text, avatar text, verified boolean, state text)
language sql stable security definer set search_path = public as $$
  select p.user_id, p.name, p.avatar,
         coalesce(p.verified and (p.verified_until is null or p.verified_until > now()), false),
         coalesce((select case when f.status = 'accepted' then 'friends' when f.requester = auth.uid() then 'sent' else 'incoming' end
                   from friendships f where f.a = least(auth.uid(), p.user_id) and f.b = greatest(auth.uid(), p.user_id)), 'none')
  from profiles p
  where p.user_id <> auth.uid() and length(trim(coalesce(p_q, ''))) >= 2
    and p.name ilike '%' || replace(replace(trim(p_q), '%', ''), '_', '') || '%'
  order by p.verified desc, p.name
  limit 25
$$;

-- Friend count for profiles
create or replace function friend_count(p_user uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from friendships where status = 'accepted' and p_user in (a, b)
$$;

revoke execute on function friend_request(uuid), friend_respond(uuid, boolean), friend_remove(uuid), my_friends(), find_people(text) from public, anon;
grant execute on function friend_request(uuid), friend_respond(uuid, boolean), friend_remove(uuid), my_friends(), find_people(text) to authenticated;
grant execute on function friend_count(uuid) to anon, authenticated;
