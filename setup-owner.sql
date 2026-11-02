-- Hottest Gist GH: owner admin page, moderation, events, top fans, newsletter list.
-- Run AFTER the earlier SQL files. Paste all into Supabase > SQL Editor > Run. Safe to run again.
-- BEFORE running: replace YOUR_EMAIL_HERE (last section) with the email you will log in with as owner.

-- ===== Admin =====
create table if not exists admins (email text primary key);
alter table comments add column if not exists hidden boolean not null default false;
alter table wall add column if not exists hidden boolean not null default false;

alter table admins enable row level security;
revoke all on admins from anon, authenticated;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where lower(email) = lower(coalesce(auth.jwt()->>'email', '')))
$$;
revoke execute on function is_admin() from public, anon;
grant execute on function is_admin() to authenticated;

-- ===== Posts written from the admin page =====
create table if not exists site_posts (
  id text primary key,
  title text not null,
  cat text not null default 'News',
  author text,
  body text,
  link text,
  images jsonb not null default '[]'::jsonb,
  pin boolean not null default false,
  status text not null default 'live',
  ts bigint not null,
  event_at bigint
);
alter table site_posts enable row level security;
drop policy if exists "read posts" on site_posts;
create policy "read posts" on site_posts for select to authenticated using (status = 'live' or is_admin());
revoke all on site_posts from anon, authenticated;
grant select on site_posts to authenticated;

create or replace function admin_save_post(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  insert into site_posts (id, title, cat, author, body, link, images, pin, status, ts, event_at)
  values (p->>'id', p->>'title', coalesce(p->>'cat', 'News'), p->>'author', p->>'body', nullif(p->>'link', ''),
          coalesce(p->'images', '[]'::jsonb), coalesce((p->>'pin')::boolean, false), coalesce(p->>'status', 'live'),
          (p->>'ts')::bigint, nullif(p->>'event_at', '')::bigint)
  on conflict (id) do update set title = excluded.title, cat = excluded.cat, author = excluded.author, body = excluded.body,
    link = excluded.link, images = excluded.images, pin = excluded.pin, status = excluded.status, ts = excluded.ts, event_at = excluded.event_at;
end $$;
revoke execute on function admin_save_post(jsonb) from public, anon;
grant execute on function admin_save_post(jsonb) to authenticated;

create or replace function admin_delete_post(p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  delete from site_posts where id = p_id;
end $$;
revoke execute on function admin_delete_post(text) from public, anon;
grant execute on function admin_delete_post(text) to authenticated;

-- ===== Photos for admin posts =====
insert into storage.buckets (id, name, public) values ('post-images', 'post-images', true) on conflict (id) do nothing;
drop policy if exists "admin upload images" on storage.objects;
create policy "admin upload images" on storage.objects for insert to authenticated with check (bucket_id = 'post-images' and is_admin());
drop policy if exists "admin delete images" on storage.objects;
create policy "admin delete images" on storage.objects for delete to authenticated using (bucket_id = 'post-images' and is_admin());

-- ===== Site settings (song of the day, sponsor) =====
create table if not exists site_settings (key text primary key, value jsonb not null default '{}'::jsonb);
alter table site_settings enable row level security;
drop policy if exists "read settings" on site_settings;
create policy "read settings" on site_settings for select to authenticated using (true);
revoke all on site_settings from anon, authenticated;
grant select on site_settings to authenticated;

create or replace function admin_set_setting(p_key text, p_value jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  insert into site_settings (key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
end $$;
revoke execute on function admin_set_setting(text, jsonb) from public, anon;
grant execute on function admin_set_setting(text, jsonb) to authenticated;

-- ===== Reports and automatic moderation =====
create table if not exists reports (
  id bigint generated always as identity primary key,
  kind text not null,
  item_id bigint not null,
  client_id text not null,
  reason text,
  created_at timestamptz not null default now(),
  unique (kind, item_id, client_id)
);
alter table reports enable row level security;
revoke all on reports from anon, authenticated;

create or replace function report_auth(p_kind text, p_id bigint, p_reason text default '') returns void
language plpgsql security definer set search_path = public as $$
declare u text := auth.uid()::text;
begin
  if u is null then raise exception 'login required'; end if;
  if p_kind not in ('comment', 'wall') then raise exception 'bad input'; end if;
  insert into reports (kind, item_id, client_id, reason) values (p_kind, p_id, u, left(coalesce(p_reason, ''), 200)) on conflict do nothing;
  if (select count(*) from reports where kind = p_kind and item_id = p_id) >= 3 then
    if p_kind = 'comment' then update comments set hidden = true where id = p_id;
    else update wall set hidden = true where id = p_id; end if;
  end if;
end $$;
revoke execute on function report_auth(text, bigint, text) from public, anon;
grant execute on function report_auth(text, bigint, text) to authenticated;

create table if not exists blocked_words (word text primary key);
alter table blocked_words enable row level security;
revoke all on blocked_words from anon, authenticated;
insert into blocked_words (word) values ('fuck'), ('shit'), ('bitch'), ('asshole'), ('bastard'), ('pussy') on conflict do nothing;

create or replace function auto_moderate() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.text ~* '(https?://|www\.)' or exists (select 1 from blocked_words w where new.text ~* ('\m' || w.word || '\M')) then
    new.hidden := true;
  end if;
  return new;
end $$;
drop trigger if exists comments_mod on comments;
create trigger comments_mod before insert on comments for each row execute function auto_moderate();
drop trigger if exists wall_mod on wall;
create trigger wall_mod before insert on wall for each row execute function auto_moderate();

create or replace function admin_set_hidden(p_kind text, p_id bigint, p_hidden boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_kind = 'comment' then update comments set hidden = p_hidden where id = p_id;
  elsif p_kind = 'wall' then update wall set hidden = p_hidden where id = p_id;
  else raise exception 'bad input'; end if;
end $$;
revoke execute on function admin_set_hidden(text, bigint, boolean) from public, anon;
grant execute on function admin_set_hidden(text, bigint, boolean) to authenticated;

-- ===== Newsletter list =====
create table if not exists subscribers (
  email text primary key,
  client_id text not null,
  created_at timestamptz not null default now()
);
alter table subscribers enable row level security;
drop policy if exists "own subscription" on subscribers;
create policy "own subscription" on subscribers for select to authenticated using (client_id = auth.uid()::text);
revoke all on subscribers from anon, authenticated;
grant select on subscribers to authenticated;

create or replace function subscribe_auth(p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare u text := auth.uid()::text; e text := lower(auth.jwt()->>'email');
begin
  if u is null or e is null or e = '' then raise exception 'no email'; end if;
  if p_on then insert into subscribers (email, client_id) values (e, u) on conflict do nothing;
  else delete from subscribers where email = e and client_id = u; end if;
end $$;
revoke execute on function subscribe_auth(boolean) from public, anon;
grant execute on function subscribe_auth(boolean) to authenticated;

-- ===== Admin dashboard data =====
create or replace function admin_moderation() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return jsonb_build_object(
    'comments', coalesce((select jsonb_agg(x) from (
      select c.id, c.post_id, c.name, c.text, c.hidden, c.created_at,
             (select count(*) from reports r where r.kind = 'comment' and r.item_id = c.id) as reports
      from comments c order by c.created_at desc limit 40) x), '[]'::jsonb),
    'wall', coalesce((select jsonb_agg(x) from (
      select w.id, w.name, w.text, w.hidden, w.created_at,
             (select count(*) from reports r where r.kind = 'wall' and r.item_id = w.id) as reports
      from wall w order by w.created_at desc limit 40) x), '[]'::jsonb),
    'subscribers', coalesce((select jsonb_agg(email) from subscribers), '[]'::jsonb)
  );
end $$;
revoke execute on function admin_moderation() from public, anon;
grant execute on function admin_moderation() to authenticated;

-- ===== Daily check-ins and top fans =====
create table if not exists checkins (
  client_id text not null,
  day date not null,
  primary key (client_id, day)
);
alter table checkins enable row level security;
drop policy if exists "own checkins" on checkins;
create policy "own checkins" on checkins for select to authenticated using (client_id = auth.uid()::text);
revoke all on checkins from anon, authenticated;
grant select on checkins to authenticated;

create or replace function checkin_auth() returns void
language plpgsql security definer set search_path = public as $$
declare u text := auth.uid()::text;
begin
  if u is null then raise exception 'login required'; end if;
  insert into checkins (client_id, day) values (u, (now() at time zone 'utc')::date) on conflict do nothing;
end $$;
revoke execute on function checkin_auth() from public, anon;
grant execute on function checkin_auth() to authenticated;

create or replace view leaderboard as
select u.id::text as client_id,
       left(coalesce(nullif(trim(u.raw_user_meta_data->>'name'), ''), nullif(trim(u.raw_user_meta_data->>'full_name'), ''), 'Fan'), 40) as name,
       (select count(*) from checkins c where c.client_id = u.id::text)::int as days,
       ((select count(*) from checkins c where c.client_id = u.id::text) * 5
        + (select count(*) from comments c where c.client_id = u.id::text and not c.hidden) * 3
        + (select count(*) from likes l where l.client_id = u.id::text)
        + (select count(*) from reactions r where r.client_id = u.id::text)
        + (select count(*) from poll_votes v where v.client_id = u.id::text) * 2)::int as points
from auth.users u;
grant select on leaderboard to authenticated;

-- ===== Make yourself the owner =====
-- Replace YOUR_EMAIL_HERE with the email you use to log in, keeping the quotes.
insert into admins (email) values ('YOUR_EMAIL_HERE') on conflict do nothing;

notify pgrst, 'reload schema';
