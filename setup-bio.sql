-- Hottest Gist GH: free link-in-bio pages (hottest-gist-gh.../@yourname).
-- Run AFTER setup-creators.sql and setup-verify.sql (setup-cover.sql too if you have it). Paste all into Supabase > SQL Editor > Run. Safe to run again.

alter table profiles add column if not exists cover text;
alter table profiles add column if not exists handle text;
alter table profiles add column if not exists links jsonb not null default '[]'::jsonb;
alter table profiles add column if not exists bio_views int not null default 0;
create unique index if not exists profiles_handle_uniq on profiles (lower(handle));

-- Same stats view as before, with the bio page fields added at the end
create or replace view creator_stats as
select p.user_id, p.name, p.bio, p.avatar,
  (p.verified and (p.verified_until is null or p.verified_until > now())) as verified,
  (select count(*) from follows f where f.followee = p.user_id)::int as followers,
  (select count(*) from fan_posts x where x.user_id = p.user_id and not x.hidden)::int as posts,
  (select count(*) from likes l join fan_posts x on l.post_id = 'fp-' || x.id::text where x.user_id = p.user_id and not x.hidden)::int as likes,
  p.verified_until,
  p.cover,
  p.handle,
  p.links,
  p.bio_views
from profiles p;
grant select on creator_stats to anon, authenticated;

-- Claim or change my page name
create or replace function set_handle(p_handle text) returns text
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); h text := lower(trim(coalesce(p_handle, '')));
begin
  if u is null then raise exception 'login required'; end if;
  h := regexp_replace(h, '^@', '');
  if h !~ '^[a-z0-9_.]{3,24}$' or h ~ '^[._]' or h ~ '[._]$' then
    raise exception 'Use 3 to 24 letters, numbers, dots or underscores';
  end if;
  if not coalesce(is_admin(), false) and h in ('admin','hottestgist','hottestgistgh','hottest','official','support','help','stories','about','privacy','terms','api','login','settings','s','images','brand','tools','supabase','null','undefined') then
    raise exception 'That name is reserved. Try another one';
  end if;
  if exists (select 1 from profiles where lower(handle) = h and user_id <> u) then raise exception 'That name is taken. Try another one'; end if;
  if exists (select 1 from blocked_words w where h ~* w.word) then raise exception 'That name is not allowed'; end if;
  update profiles set handle = h where user_id = u;
  if not found then raise exception 'Set up your profile first'; end if;
  return h;
end $$;

-- Save my links: [{"label": "...", "url": "https://..."}], up to 8
create or replace function save_links(p_links jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); i jsonb;
begin
  if u is null then raise exception 'login required'; end if;
  if jsonb_typeof(p_links) <> 'array' or jsonb_array_length(p_links) > 8 then raise exception 'You can add up to 8 links'; end if;
  for i in select * from jsonb_array_elements(p_links) loop
    if jsonb_typeof(i) <> 'object' or length(coalesce(i->>'label', '')) not between 1 and 30
       or coalesce(i->>'url', '') !~* '^(https://|mailto:|tel:)' or length(i->>'url') > 300 then
      raise exception 'Each link needs a name and an address starting with https://';
    end if;
  end loop;
  update profiles set links = p_links where user_id = u;
end $$;

-- Count a visit to a bio page
create or replace function bio_view(p_handle text) returns void
language sql security definer set search_path = public as $$
  update profiles set bio_views = bio_views + 1 where lower(handle) = lower(p_handle);
$$;

revoke execute on function set_handle(text), save_links(jsonb) from public, anon;
grant execute on function set_handle(text), save_links(jsonb) to authenticated;
grant execute on function bio_view(text) to anon, authenticated;
notify pgrst, 'reload schema';
