-- Hottest Gist GH: the official page shown at the top of Friends.
-- It is the profile of the site owner (the email in the admins table).
-- Paste into Supabase > SQL Editor > Run. Safe to run again.

create or replace function official_account() returns uuid
language sql stable security definer set search_path = public, auth as $$
  select p.user_id
  from profiles p
  join auth.users u on u.id = p.user_id
  join admins a on lower(a.email) = lower(u.email)
  order by p.created_at
  limit 1
$$;
revoke execute on function official_account() from public;
grant execute on function official_account() to anon, authenticated;

-- People who follow me (for "Follow back" and "Follows you")
create or replace function my_followers()
returns table (user_id uuid, name text, avatar text, verified boolean, since timestamptz)
language sql stable security definer set search_path = public as $$
  select f.follower, p.name, p.avatar,
         coalesce(p.verified and (p.verified_until is null or p.verified_until > now()), false),
         f.created_at
  from follows f join profiles p on p.user_id = f.follower
  where f.followee = auth.uid()
  order by f.created_at desc
  limit 300
$$;
revoke execute on function my_followers() from public, anon;
grant execute on function my_followers() to authenticated;
