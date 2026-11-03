-- Hottest Gist GH: edit your own fan posts.
-- Run AFTER setup-creators.sql. Paste into Supabase > SQL Editor > Run. Safe to run again.

alter table fan_posts add column if not exists edited_at timestamptz;

create or replace function edit_fan_post(p_id bigint, p_text text, p_images jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); pre text; i jsonb; r fan_posts; imgs jsonb;
begin
  if u is null then raise exception 'login required'; end if;
  select * into r from fan_posts where id = p_id;
  if r.id is null or r.user_id <> u then raise exception 'not your post'; end if;
  pre := 'https://zcejqihsmyxplerihser.supabase.co/storage/v1/object/public/fan-media/' || u::text || '/';
  p_text := trim(coalesce(p_text, ''));
  imgs := coalesce(p_images, r.images, '[]'::jsonb);
  if length(p_text) > 500 or jsonb_typeof(imgs) <> 'array' or jsonb_array_length(imgs) > 3 then raise exception 'bad post'; end if;
  for i in select * from jsonb_array_elements(imgs) loop
    if jsonb_typeof(i) <> 'string' or left(i #>> '{}', length(pre)) <> pre then raise exception 'bad image'; end if;
  end loop;
  if p_text = '' and jsonb_array_length(imgs) = 0 and coalesce(r.video, '') = '' and coalesce(r.link, '') = '' then raise exception 'empty post'; end if;
  if (select count(*) from fan_posts where user_id = u and edited_at > now() - interval '1 minute') >= 5 then raise exception 'slow down'; end if;
  update fan_posts set text = p_text, images = imgs, edited_at = now() where id = p_id;
end $$;
revoke execute on function edit_fan_post(bigint, text, jsonb) from public, anon;
grant execute on function edit_fan_post(bigint, text, jsonb) to authenticated;

-- Edited text goes through the same safety filter as new posts
drop trigger if exists fan_posts_mod_upd on fan_posts;
create trigger fan_posts_mod_upd before update of text on fan_posts for each row execute function auto_moderate();
