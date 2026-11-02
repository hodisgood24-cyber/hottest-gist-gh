-- Hottest Gist GH: phone notifications (who signed up for alerts).
-- Paste all into Supabase > SQL Editor > Run. Safe to run again.
create table if not exists push_subs (
  endpoint text primary key,
  p256dh text not null,
  auth text not null,
  user_id uuid,
  created_at timestamptz not null default now()
);
alter table push_subs enable row level security;
revoke all on push_subs from anon, authenticated;

create or replace function save_push(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_endpoint is null or p_endpoint !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'bad endpoint'; end if;
  insert into push_subs (endpoint, p256dh, auth, user_id) values (p_endpoint, p_p256dh, p_auth, auth.uid())
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, user_id = coalesce(excluded.user_id, push_subs.user_id);
end $$;
create or replace function remove_push(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from push_subs where endpoint = p_endpoint;
$$;
grant execute on function save_push(text, text, text) to anon, authenticated;
grant execute on function remove_push(text) to anon, authenticated;
