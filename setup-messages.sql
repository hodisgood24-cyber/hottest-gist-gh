-- Hottest Gist GH: private messages between friends.
-- Run AFTER setup-friends.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

create table if not exists messages (
  id bigint generated always as identity primary key,
  sender uuid not null,
  recipient uuid not null,
  body text not null check (length(body) between 1 and 1000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  check (sender <> recipient)
);
create index if not exists messages_pair on messages (sender, recipient, id);
create index if not exists messages_inbox on messages (recipient, read_at);
alter table messages enable row level security;
drop policy if exists "own messages" on messages;
create policy "own messages" on messages for select to authenticated using (auth.uid() in (sender, recipient));
revoke all on messages from anon, authenticated;
grant select on messages to authenticated;

-- Send a message (friends only)
create or replace function send_message(p_to uuid, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_text text := trim(coalesce(p_body, '')); v_id bigint;
begin
  if v_me is null then raise exception 'login required'; end if;
  if v_text = '' then raise exception 'Type a message first'; end if;
  if length(v_text) > 1000 then raise exception 'Messages can be up to 1000 characters'; end if;
  if not exists (select 1 from friendships f where f.a = least(v_me, p_to) and f.b = greatest(v_me, p_to) and f.status = 'accepted') then
    raise exception 'You can only message your friends';
  end if;
  if (select count(*) from messages m where m.sender = v_me and m.created_at > now() - interval '1 minute') >= 20 then
    raise exception 'Slow down a little, then try again';
  end if;
  insert into messages (sender, recipient, body) values (v_me, p_to, v_text) returning id into v_id;
  return v_id;
end $$;

-- One conversation (newer than p_after)
create or replace function chat_with(p_user uuid, p_after bigint default 0)
returns table (id bigint, mine boolean, body text, created_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = public as $$
  select * from (
    select m.id, m.sender = auth.uid(), m.body, m.created_at, m.read_at
    from messages m
    where ((m.sender = auth.uid() and m.recipient = p_user) or (m.sender = p_user and m.recipient = auth.uid()))
      and m.id > coalesce(p_after, 0)
    order by m.id desc
    limit 200
  ) x order by x.id
$$;

-- Mark a conversation as read
create or replace function mark_chat_read(p_user uuid) returns void
language sql security definer set search_path = public as $$
  update messages set read_at = now() where recipient = auth.uid() and sender = p_user and read_at is null;
$$;

-- My inbox: one row per person, newest first
create or replace function my_chats()
returns table (user_id uuid, name text, avatar text, verified boolean, last_body text, last_at timestamptz, last_mine boolean, unread int)
language sql stable security definer set search_path = public as $$
  with m as (
    select case when sender = auth.uid() then recipient else sender end as other, body, created_at, sender, id
    from messages where auth.uid() in (sender, recipient)
  ), last as (
    select distinct on (other) other, body, created_at, sender from m order by other, id desc
  )
  select l.other, p.name, p.avatar,
         coalesce(p.verified and (p.verified_until is null or p.verified_until > now()), false),
         l.body, l.created_at, l.sender = auth.uid(),
         (select count(*) from messages x where x.recipient = auth.uid() and x.sender = l.other and x.read_at is null)::int
  from last l join profiles p on p.user_id = l.other
  order by l.created_at desc
  limit 100
$$;

create or replace function unread_messages() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from messages where recipient = auth.uid() and read_at is null
$$;

revoke execute on function send_message(uuid, text), chat_with(uuid, bigint), mark_chat_read(uuid), my_chats(), unread_messages() from public, anon;
grant execute on function send_message(uuid, text), chat_with(uuid, bigint), mark_chat_read(uuid), my_chats(), unread_messages() to authenticated;
