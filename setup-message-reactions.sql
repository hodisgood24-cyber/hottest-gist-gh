-- Hottest Gist GH: emoji reactions on private messages.
-- Run AFTER setup-messages.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

create table if not exists message_reactions (
  message_id bigint not null references messages(id) on delete cascade,
  user_id uuid not null,
  emoji text not null,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);
alter table message_reactions enable row level security;
revoke all on message_reactions from anon, authenticated;

-- React to a message in one of your chats. Same emoji again or an empty string removes it.
create or replace function react_message(p_id bigint, p_emoji text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'login required'; end if;
  if not exists (select 1 from messages m where m.id = p_id and u in (m.sender, m.recipient)) then raise exception 'not allowed'; end if;
  if coalesce(p_emoji, '') = '' then
    delete from message_reactions where message_id = p_id and user_id = u;
    return;
  end if;
  if p_emoji <> all (array[chr(10084) || chr(65039), chr(128514), chr(128077), chr(128558), chr(128546), chr(128591), chr(128293)]) then raise exception 'bad emoji'; end if;
  insert into message_reactions (message_id, user_id, emoji) values (p_id, u, p_emoji)
  on conflict (message_id, user_id) do update set emoji = excluded.emoji, created_at = now();
end $$;

-- Reactions in one conversation (latest 300 messages)
create or replace function chat_reactions(p_user uuid)
returns table (message_id bigint, mine boolean, emoji text)
language sql stable security definer set search_path = public as $$
  select r.message_id, r.user_id = auth.uid(), r.emoji
  from message_reactions r
  join messages m on m.id = r.message_id
  where ((m.sender = auth.uid() and m.recipient = p_user) or (m.sender = p_user and m.recipient = auth.uid()))
    and m.id > coalesce((select max(x.id) - 300 from messages x
                         where (x.sender = auth.uid() and x.recipient = p_user) or (x.sender = p_user and x.recipient = auth.uid())), 0)
$$;

revoke execute on function react_message(bigint, text), chat_reactions(uuid) from public, anon;
grant execute on function react_message(bigint, text), chat_reactions(uuid) to authenticated;

notify pgrst, 'reload schema';
