-- Hottest Gist GH: likes on comments, "Liked by author", and a bell alert when someone likes your comment.
-- Run AFTER setup-comment-media.sql, setup-notify.sql and setup-official.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

create table if not exists comment_likes (
  comment_id bigint not null references comments (id) on delete cascade,
  user_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);
create index if not exists comment_likes_user on comment_likes (user_id);
alter table comment_likes enable row level security;
revoke all on comment_likes from anon, authenticated;

-- Who wrote this post (fan post owner, or the official Hottest Gist GH page for news)
create or replace function post_author(p_post text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare a uuid;
begin
  if p_post like 'fp-%' then
    select user_id into a from fan_posts where 'fp-' || id::text = p_post;
    return a;
  end if;
  begin
    a := official_account();
  exception when others then a := null;
  end;
  return a;
end $$;

-- Like or unlike a comment
create or replace function like_comment(p_id bigint, p_on boolean) returns int
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); c comments;
begin
  if u is null then raise exception 'login required'; end if;
  select * into c from comments where id = p_id and hidden = false;
  if c.id is null then raise exception 'That comment is no longer there'; end if;
  if p_on then
    insert into comment_likes (comment_id, user_id) values (p_id, u) on conflict do nothing;
    if found and c.client_id ~ '^[0-9a-f-]{36}$' then
      begin
        perform add_note(c.client_id::uuid, u, 'comment_like', c.post_id,
          case when u = post_author(c.post_id) then '[author] ' else '' end || coalesce(nullif(c.text, ''), case c.kind when 'image' then 'your photo' when 'video' then 'your video' else '' end));
      exception when others then null;
      end;
    end if;
  else
    delete from comment_likes where comment_id = p_id and user_id = u;
  end if;
  return (select count(*)::int from comment_likes where comment_id = p_id);
end $$;

-- Likes for every comment on a post: how many, did I like it, did the author like it
create or replace function comment_likes_for(p_post text)
returns table (comment_id bigint, n int, mine boolean, by_author boolean)
language sql stable security definer set search_path = public as $$
  select l.comment_id, count(*)::int,
         coalesce(bool_or(l.user_id = auth.uid()), false),
         coalesce(bool_or(l.user_id = post_author(p_post)), false)
  from comment_likes l join comments c on c.id = l.comment_id
  where c.post_id = p_post and not c.hidden
  group by l.comment_id
$$;

-- Bell alerts can now say "liked your comment"
alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('like', 'comment', 'reply', 'follow', 'friend_request', 'friend_accept', 'comment_like'));

revoke execute on function like_comment(bigint, boolean) from public, anon;
grant execute on function like_comment(bigint, boolean) to authenticated;
revoke execute on function post_author(text) from public;
grant execute on function post_author(text), comment_likes_for(text) to anon, authenticated;
notify pgrst, 'reload schema';
