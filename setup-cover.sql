-- Hottest Gist GH: profile cover photos, and removing a profile picture.
-- Run AFTER setup-creators.sql and setup-verify.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

alter table profiles add column if not exists cover text;

-- Same view as before, with the cover photo added at the end
create or replace view creator_stats as
select p.user_id, p.name, p.bio, p.avatar,
  (p.verified and (p.verified_until is null or p.verified_until > now())) as verified,
  (select count(*) from follows f where f.followee = p.user_id)::int as followers,
  (select count(*) from fan_posts x where x.user_id = p.user_id and not x.hidden)::int as posts,
  (select count(*) from likes l join fan_posts x on l.post_id = 'fp-' || x.id::text where x.user_id = p.user_id and not x.hidden)::int as likes,
  p.verified_until,
  p.cover
from profiles p;
grant select on creator_stats to anon, authenticated;

-- Set or remove my cover photo ('' removes it)
create or replace function save_cover(p_cover text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); pre text;
begin
  if u is null then raise exception 'login required'; end if;
  pre := 'https://zcejqihsmyxplerihser.supabase.co/storage/v1/object/public/fan-media/' || u::text || '/';
  if coalesce(p_cover, '') <> '' and left(p_cover, length(pre)) <> pre then raise exception 'bad cover'; end if;
  update profiles set cover = nullif(p_cover, '') where user_id = u;
end $$;

-- Remove my profile picture
create or replace function remove_avatar() returns void
language sql security definer set search_path = public as $$
  update profiles set avatar = null where user_id = auth.uid();
$$;

revoke execute on function save_cover(text), remove_avatar() from public, anon;
grant execute on function save_cover(text), remove_avatar() to authenticated;
notify pgrst, 'reload schema';
