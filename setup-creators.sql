-- Hottest Gist GH: fan accounts that can post, follow, and grow.
-- Run AFTER setup-owner.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

-- ===== Profiles =====
create table if not exists profiles (
  user_id uuid primary key,
  name text not null,
  bio text not null default '',
  avatar text,
  verified boolean not null default false,
  created_at timestamptz not null default now()
);
alter table profiles enable row level security;
drop policy if exists "read profiles" on profiles;
create policy "read profiles" on profiles for select to authenticated using (true);
revoke all on profiles from anon, authenticated;
grant select on profiles to authenticated;

create or replace function save_profile(p_name text, p_bio text, p_avatar text default null) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); pre text;
begin
  if u is null then raise exception 'login required'; end if;
  pre := 'https://zcejqihsmyxplerihser.supabase.co/storage/v1/object/public/fan-media/' || u::text || '/';
  if length(trim(coalesce(p_name, ''))) < 1 or length(p_name) > 40 or length(coalesce(p_bio, '')) > 160 then raise exception 'bad input'; end if;
  if p_avatar is not null and p_avatar <> '' and left(p_avatar, length(pre)) <> pre then raise exception 'bad avatar'; end if;
  if exists (select 1 from blocked_words w where (p_name || ' ' || coalesce(p_bio, '')) ~* ('\m' || w.word || '\M'))
     or coalesce(p_bio, '') ~* '(https?://|www\.)' then raise exception 'not allowed'; end if;
  insert into profiles (user_id, name, bio, avatar) values (u, trim(p_name), trim(coalesce(p_bio, '')), nullif(p_avatar, ''))
  on conflict (user_id) do update set name = excluded.name, bio = excluded.bio, avatar = coalesce(nullif(p_avatar, ''), profiles.avatar);
end $$;
revoke execute on function save_profile(text, text, text) from public, anon;
grant execute on function save_profile(text, text, text) to authenticated;

-- ===== Fan posts =====
create table if not exists fan_posts (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  text text not null default '',
  images jsonb not null default '[]'::jsonb,
  link text,
  video text,
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists fan_posts_time on fan_posts (created_at desc);
create index if not exists fan_posts_user on fan_posts (user_id);
alter table fan_posts enable row level security;
drop policy if exists "read fan posts" on fan_posts;
create policy "read fan posts" on fan_posts for select to authenticated using (hidden = false or user_id = auth.uid() or is_admin());
revoke all on fan_posts from anon, authenticated;
grant select on fan_posts to authenticated;

drop trigger if exists fan_posts_mod on fan_posts;
create trigger fan_posts_mod before insert on fan_posts for each row execute function auto_moderate();

create or replace function add_fan_post(p_text text, p_images jsonb default '[]'::jsonb, p_link text default null, p_video text default null) returns bigint
language plpgsql security definer set search_path = public, auth as $$
declare u uuid := auth.uid(); pre text; i jsonb; nid bigint; n text;
begin
  if u is null then raise exception 'login required'; end if;
  pre := 'https://zcejqihsmyxplerihser.supabase.co/storage/v1/object/public/fan-media/' || u::text || '/';
  p_text := trim(coalesce(p_text, ''));
  p_images := coalesce(p_images, '[]'::jsonb);
  if length(p_text) > 500 or jsonb_typeof(p_images) <> 'array' or jsonb_array_length(p_images) > 3 then raise exception 'bad post'; end if;
  if p_text = '' and jsonb_array_length(p_images) = 0 and coalesce(p_link, '') = '' and coalesce(p_video, '') = '' then raise exception 'empty post'; end if;
  for i in select * from jsonb_array_elements(p_images) loop
    if jsonb_typeof(i) <> 'string' or left(i #>> '{}', length(pre)) <> pre then raise exception 'bad image'; end if;
  end loop;
  if coalesce(p_video, '') <> '' and left(p_video, length(pre)) <> pre then raise exception 'bad video'; end if;
  if coalesce(p_link, '') <> '' and (length(p_link) > 300 or p_link !~* '^https://([a-z0-9-]+\.)*(youtube\.com|youtu\.be|spotify\.com|audiomack\.com|tiktok\.com|facebook\.com|fb\.watch|instagram\.com|soundcloud\.com|boomplay\.com|apple\.com)/') then
    raise exception 'link not allowed';
  end if;
  if (select count(*) from fan_posts where user_id = u and created_at > now() - interval '1 minute') >= 2
     or (select count(*) from fan_posts where user_id = u and created_at > now() - interval '1 day') >= 10 then
    raise exception 'slow down';
  end if;
  if not exists (select 1 from profiles where user_id = u) then
    select left(coalesce(nullif(trim(raw_user_meta_data->>'name'), ''), 'Fan'), 40) into n from auth.users where id = u;
    insert into profiles (user_id, name) values (u, coalesce(n, 'Fan'));
  end if;
  insert into fan_posts (user_id, text, images, link, video)
  values (u, p_text, p_images, nullif(p_link, ''), nullif(p_video, '')) returning id into nid;
  return nid;
end $$;
revoke execute on function add_fan_post(text, jsonb, text, text) from public, anon;
grant execute on function add_fan_post(text, jsonb, text, text) to authenticated;

create or replace function delete_fan_post(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  delete from fan_posts where id = p_id and (user_id = auth.uid() or is_admin());
end $$;
revoke execute on function delete_fan_post(bigint) from public, anon;
grant execute on function delete_fan_post(bigint) to authenticated;

-- ===== Follows =====
create table if not exists follows (
  follower uuid not null,
  followee uuid not null,
  created_at timestamptz not null default now(),
  primary key (follower, followee),
  check (follower <> followee)
);
alter table follows enable row level security;
drop policy if exists "own follows" on follows;
create policy "own follows" on follows for select to authenticated using (follower = auth.uid());
revoke all on follows from anon, authenticated;
grant select on follows to authenticated;

create or replace function toggle_follow(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'login required'; end if;
  if p_user = u or not exists (select 1 from profiles where user_id = p_user) then raise exception 'bad input'; end if;
  if p_on then insert into follows (follower, followee) values (u, p_user) on conflict do nothing;
  else delete from follows where follower = u and followee = p_user; end if;
end $$;
revoke execute on function toggle_follow(uuid, boolean) from public, anon;
grant execute on function toggle_follow(uuid, boolean) to authenticated;

-- ===== Creator stats (names, followers, posts, likes, score) =====
create or replace view creator_stats as
select p.user_id, p.name, p.bio, p.avatar, p.verified,
  (select count(*) from follows f where f.followee = p.user_id)::int as followers,
  (select count(*) from fan_posts x where x.user_id = p.user_id and not x.hidden)::int as posts,
  (select count(*) from likes l join fan_posts x on l.post_id = 'fp-' || x.id::text where x.user_id = p.user_id and not x.hidden)::int as likes
from profiles p;
grant select on creator_stats to authenticated;

-- ===== Photos and videos from fans =====
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fan-media', 'fan-media', true, 52428800, array['image/jpeg','image/png','image/webp','video/mp4','video/webm','video/quicktime'])
on conflict (id) do update set file_size_limit = 52428800, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "fans upload own" on storage.objects;
create policy "fans upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'fan-media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "fans delete own" on storage.objects;
create policy "fans delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'fan-media' and ((storage.foldername(name))[1] = auth.uid()::text or is_admin()));

-- ===== Reports and admin tools now cover fan posts =====
create or replace function report_auth(p_kind text, p_id bigint, p_reason text default '') returns void
language plpgsql security definer set search_path = public as $$
declare u text := auth.uid()::text;
begin
  if u is null then raise exception 'login required'; end if;
  if p_kind not in ('comment', 'wall', 'fan') then raise exception 'bad input'; end if;
  insert into reports (kind, item_id, client_id, reason) values (p_kind, p_id, u, left(coalesce(p_reason, ''), 200)) on conflict do nothing;
  if (select count(*) from reports where kind = p_kind and item_id = p_id) >= 3 then
    if p_kind = 'comment' then update comments set hidden = true where id = p_id;
    elsif p_kind = 'wall' then update wall set hidden = true where id = p_id;
    else update fan_posts set hidden = true where id = p_id; end if;
  end if;
end $$;

create or replace function admin_set_hidden(p_kind text, p_id bigint, p_hidden boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_kind = 'comment' then update comments set hidden = p_hidden where id = p_id;
  elsif p_kind = 'wall' then update wall set hidden = p_hidden where id = p_id;
  elsif p_kind = 'fan' then update fan_posts set hidden = p_hidden where id = p_id;
  else raise exception 'bad input'; end if;
end $$;

create or replace function admin_set_verified(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  update profiles set verified = p_on where user_id = p_user;
end $$;
revoke execute on function admin_set_verified(uuid, boolean) from public, anon;
grant execute on function admin_set_verified(uuid, boolean) to authenticated;

create or replace function admin_creators() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return jsonb_build_object(
    'fans', coalesce((select jsonb_agg(x) from (
      select f.id, p.name, f.text, f.hidden, f.created_at,
             (select count(*) from reports r where r.kind = 'fan' and r.item_id = f.id) as reports
      from fan_posts f left join profiles p on p.user_id = f.user_id order by f.created_at desc limit 40) x), '[]'::jsonb),
    'creators', coalesce((select jsonb_agg(y) from (
      select user_id, name, verified, followers, posts from creator_stats order by followers desc, posts desc limit 40) y), '[]'::jsonb)
  );
end $$;
revoke execute on function admin_creators() from public, anon;
grant execute on function admin_creators() to authenticated;

notify pgrst, 'reload schema';
