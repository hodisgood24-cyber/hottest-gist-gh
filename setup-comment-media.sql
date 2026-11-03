-- Hottest Gist GH: photos and videos in comments and replies, and replying to replies.
-- Run AFTER setup-fun.sql (and setup-notify.sql if you have it). Paste all into Supabase > SQL Editor > Run. Safe to run again.

alter table comments add column if not exists parent_id bigint;
alter table comments add column if not exists kind text not null default 'text';
alter table comments add column if not exists media text;
alter table comments drop constraint if exists comments_kind_check;
alter table comments add constraint comments_kind_check check (kind in ('text', 'image', 'video'));

drop function if exists add_comment_auth(text, text);
drop function if exists add_comment_auth(text, text, bigint);
create or replace function add_comment_auth(p_post text, p_text text, p_parent bigint default null,
                                            p_kind text default 'text', p_media text default null)
returns bigint language plpgsql security definer set search_path = public, auth as $$
declare u text := auth.uid()::text; n text; t text := trim(coalesce(p_text, '')); k text := coalesce(nullif(p_kind, ''), 'text');
        par bigint := p_parent; top bigint; pre text; nid bigint;
begin
  if u is null then raise exception 'login required'; end if;
  if k not in ('text', 'image', 'video') then raise exception 'bad kind'; end if;
  if k = 'text' and length(t) < 1 then raise exception 'Write something first'; end if;
  if length(t) > 500 or length(p_post) > 100 then raise exception 'Comments can be up to 500 characters'; end if;
  if k <> 'text' then
    pre := 'https://zcejqihsmyxplerihser.supabase.co/storage/v1/object/public/fan-media/' || u || '/';
    if coalesce(p_media, '') = '' or left(p_media, length(pre)) <> pre then raise exception 'bad media'; end if;
  end if;
  if par is not null then
    select coalesce(c.parent_id, c.id) into top from comments c where c.id = par and c.post_id = p_post and c.hidden = false;
    if top is null then raise exception 'That comment is no longer there'; end if;
    par := top;  -- replies to a reply go in the same thread
  end if;
  if (select count(*) from comments where client_id = u and created_at > now() - interval '1 minute') >= 5 then
    raise exception 'Slow down a little, then try again';
  end if;
  select left(coalesce(p.name, nullif(trim(x.raw_user_meta_data->>'name'), ''), nullif(trim(x.raw_user_meta_data->>'full_name'), ''), 'Fan'), 40)
    into n from auth.users x left join profiles p on p.user_id = x.id where x.id = auth.uid();
  insert into comments (post_id, client_id, name, text, parent_id, kind, media)
  values (p_post, u, coalesce(n, 'Fan'), t, par, k, case when k = 'text' then null else p_media end)
  returning id into nid;
  return nid;
end $$;
revoke execute on function add_comment_auth(text, text, bigint, text, text) from public, anon;
grant execute on function add_comment_auth(text, text, bigint, text, text) to authenticated;
notify pgrst, 'reload schema';
