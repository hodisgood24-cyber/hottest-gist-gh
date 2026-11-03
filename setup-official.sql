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
