-- Hottest Gist GH: "Submit your song" + paid "Featured artist" spotlight.
-- Run AFTER setup-owner.sql, setup-creators.sql and setup-paystack.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

create table if not exists song_submissions (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  artist text not null,
  song text not null,
  story text not null default '',
  contact text not null,
  link text,
  image text,
  status text not null default 'new' check (status in ('new', 'approved', 'published', 'rejected')),
  featured_until timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists song_submissions_time on song_submissions (created_at desc);
alter table song_submissions enable row level security;
drop policy if exists "own submissions" on song_submissions;
create policy "own submissions" on song_submissions for select to authenticated using (user_id = auth.uid());
revoke all on song_submissions from anon, authenticated;
grant select on song_submissions to authenticated;

-- Everyone can see the current featured artists (approved and paid/featured)
create or replace view featured_spotlight as
  select id, artist, song, story, link, image, featured_until
  from song_submissions
  where status in ('approved', 'published') and featured_until > now()
  order by featured_until desc;
grant select on featured_spotlight to anon, authenticated;

-- New Releases: approved song submissions from the last 30 days (everyone can see)
create or replace view new_releases as
  select id, artist, song, link, image, created_at
  from song_submissions
  where status in ('approved', 'published') and created_at > now() - interval '30 days'
  order by created_at desc
  limit 20;
grant select on new_releases to anon, authenticated;

create or replace function submit_song(p_artist text, p_song text, p_story text, p_contact text, p_link text default null, p_image text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); nid bigint; pre text;
begin
  if u is null then raise exception 'login required'; end if;
  if length(trim(coalesce(p_artist,''))) < 2 or length(trim(coalesce(p_song,''))) < 1 then raise exception 'Add the artist name and the song title'; end if;
  if length(trim(coalesce(p_contact,''))) < 5 then raise exception 'Add a WhatsApp number or email so we can reach you'; end if;
  if p_link is not null and p_link <> '' and p_link !~* '^https://' then raise exception 'The link must start with https://'; end if;
  pre := 'https://zcejqihsmyxplerihser.supabase.co/storage/v1/object/public/fan-media/' || u::text || '/';
  if p_image is not null and p_image <> '' and left(p_image, length(pre)) <> pre then raise exception 'bad image'; end if;
  if (select count(*) from song_submissions where user_id = u and created_at > now() - interval '1 day') >= 3 then
    raise exception 'You can send 3 songs a day. Try again tomorrow.';
  end if;
  insert into song_submissions (user_id, artist, song, story, contact, link, image)
  values (u, left(trim(p_artist), 60), left(trim(p_song), 80), left(coalesce(p_story, ''), 800), left(trim(p_contact), 80),
          nullif(left(coalesce(p_link, ''), 300), ''), nullif(p_image, ''))
  returning id into nid;
  return nid;
end $$;
revoke execute on function submit_song(text, text, text, text, text, text) from public, anon;
grant execute on function submit_song(text, text, text, text, text, text) to authenticated;

-- Admin: see and manage submissions
create or replace function admin_submissions() returns setof song_submissions
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return query select * from song_submissions order by (status = 'new') desc, created_at desc limit 200;
end $$;
create or replace function admin_set_submission(p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  update song_submissions set status = p_status where id = p_id;
end $$;
create or replace function admin_feature_song(p_id bigint, p_days int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_days <= 0 then update song_submissions set featured_until = null where id = p_id;
  else update song_submissions set featured_until = greatest(coalesce(featured_until, now()), now()) + (p_days * interval '1 day'),
       status = case when status in ('new', 'rejected') then 'approved' else status end where id = p_id; end if;
end $$;
revoke execute on function admin_submissions(), admin_set_submission(bigint, text), admin_feature_song(bigint, int) from public, anon;
grant execute on function admin_submissions(), admin_set_submission(bigint, text), admin_feature_song(bigint, int) to authenticated;

-- Paid spotlight: only the server (after a Paystack payment) can call this. Safe to run twice for the same payment.
create or replace function grant_song_feature(p_song bigint, p_ref text, p_amount int, p_currency text, p_days int default 7) returns boolean
language plpgsql security definer set search_path = public as $$
declare uid uuid; added int;
begin
  select user_id into uid from song_submissions where id = p_song;
  if uid is null then return false; end if;
  insert into payments (reference, user_id, amount, currency, months) values (p_ref, uid, p_amount, p_currency, 0)
  on conflict (reference) do nothing;
  get diagnostics added = row_count;
  if added = 0 then return false; end if;
  update song_submissions set featured_until = greatest(coalesce(featured_until, now()), now()) + (p_days * interval '1 day') where id = p_song;
  return true;
end $$;
revoke execute on function grant_song_feature(bigint, text, int, text, int) from public, anon, authenticated;
grant execute on function grant_song_feature(bigint, text, int, text, int) to service_role;

notify pgrst, 'reload schema';
