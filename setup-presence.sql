-- Online / last seen. Run once in Supabase SQL Editor.
create table if not exists user_presence (
  user_id uuid primary key,
  seen_at timestamptz not null default now(),
  hidden boolean not null default false
);
alter table user_presence enable row level security;
revoke all on user_presence from anon, authenticated;

create or replace function presence_ping(p_hide boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into user_presence(user_id, seen_at, hidden) values (auth.uid(), now(), coalesce(p_hide, false))
  on conflict (user_id) do update set seen_at = now(), hidden = coalesce(p_hide, false);
end $$;

-- People who hide their status are not returned.
create or replace function presence_get(p_users uuid[]) returns table (user_id uuid, seen_at timestamptz)
language sql stable security definer set search_path = public as $$
  select u.user_id, u.seen_at from user_presence u
  where u.user_id = any(p_users) and not u.hidden and auth.uid() is not null
  limit 200;
$$;

grant execute on function presence_ping(boolean) to authenticated;
grant execute on function presence_get(uuid[]) to authenticated;
