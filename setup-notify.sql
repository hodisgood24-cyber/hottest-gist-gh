-- Hottest Gist GH: notification bell.
-- Tells fans when someone likes or comments on their post, replies to their comment, or follows them.
-- Run AFTER setup-creators.sql and setup-fun.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

create table if not exists notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  actor uuid,
  actor_name text not null default 'A fan',
  kind text not null check (kind in ('like', 'comment', 'reply', 'follow')),
  post_id text,
  snippet text not null default '',
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user on notifications (user_id, created_at desc);
alter table notifications enable row level security;
drop policy if exists "own notifications" on notifications;
create policy "own notifications" on notifications for select to authenticated using (user_id = auth.uid());
revoke all on notifications from anon, authenticated;
grant select on notifications to authenticated;

-- Mark all my notifications as read.
create or replace function mark_notes_read() returns void
language sql security definer set search_path = public as $$
  update notifications set read = true where user_id = auth.uid() and read = false;
$$;
grant execute on function mark_notes_read() to authenticated;

-- Helper: add one notification (skips notifying yourself).
create or replace function add_note(p_user uuid, p_actor uuid, p_kind text, p_post text, p_snip text) returns void
language plpgsql security definer set search_path = public as $$
declare n text;
begin
  if p_user is null or p_user = p_actor then return; end if;
  select name into n from profiles where user_id = p_actor;
  insert into notifications (user_id, actor, actor_name, kind, post_id, snippet)
  values (p_user, p_actor, coalesce(n, 'A fan'), p_kind, p_post, left(coalesce(p_snip, ''), 120));
  -- keep each person's list small
  delete from notifications where user_id = p_user and id not in (
    select id from notifications where user_id = p_user order by created_at desc limit 100);
end $$;
revoke all on function add_note(uuid, uuid, text, text, text) from public, anon, authenticated;

-- Likes on a fan post
create or replace function note_like() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner uuid;
begin
  if new.post_id like 'fp-%' then
    select user_id into owner from fan_posts where 'fp-' || id::text = new.post_id;
    begin perform add_note(owner, new.client_id::uuid, 'like', new.post_id, ''); exception when others then null; end;
  end if;
  return new;
end $$;
drop trigger if exists likes_note on likes;
create trigger likes_note after insert on likes for each row execute function note_like();

-- Comments on a fan post, and replies to a comment
create or replace function note_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner uuid; parent_user text;
begin
  begin
    if new.parent_id is not null then
      select client_id into parent_user from comments where id = new.parent_id;
      perform add_note(parent_user::uuid, new.client_id::uuid, 'reply', new.post_id, new.text);
    end if;
    if new.post_id like 'fp-%' then
      select user_id into owner from fan_posts where 'fp-' || id::text = new.post_id;
      if parent_user is null or owner::text <> parent_user then
        perform add_note(owner, new.client_id::uuid, 'comment', new.post_id, new.text);
      end if;
    end if;
  exception when others then null;
  end;
  return new;
end $$;
drop trigger if exists comments_note on comments;
create trigger comments_note after insert on comments for each row execute function note_comment();

-- New followers
create or replace function note_follow() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin perform add_note(new.followee, new.follower, 'follow', null, ''); exception when others then null; end;
  return new;
end $$;
drop trigger if exists follows_note on follows;
create trigger follows_note after insert on follows for each row execute function note_follow();
