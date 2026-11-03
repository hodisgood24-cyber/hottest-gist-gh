-- Hottest Gist GH: pictures, videos and voice notes in messages.
-- Run AFTER setup-messages.sql and setup-voice.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

alter table messages add column if not exists kind text not null default 'text';
alter table messages add column if not exists media text;
alter table messages drop constraint if exists messages_body_check;
alter table messages drop constraint if exists messages_body_len;
alter table messages add constraint messages_body_len check (length(body) <= 1000);
alter table messages drop constraint if exists messages_kind_check;
alter table messages add constraint messages_kind_check check (kind in ('text', 'image', 'video', 'voice'));

drop function if exists send_message(uuid, text);
create or replace function send_message(p_to uuid, p_body text default '', p_kind text default 'text', p_media text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_text text := trim(coalesce(p_body, '')); v_kind text := coalesce(p_kind, 'text'); v_pre text; v_id bigint;
begin
  if v_me is null then raise exception 'login required'; end if;
  if v_kind not in ('text', 'image', 'video', 'voice') then raise exception 'bad kind'; end if;
  if length(v_text) > 1000 then raise exception 'Messages can be up to 1000 characters'; end if;
  if v_kind = 'text' and v_text = '' then raise exception 'Type a message first'; end if;
  if v_kind <> 'text' then
    v_pre := 'https://zcejqihsmyxplerihser.supabase.co/storage/v1/object/public/fan-media/' || v_me::text || '/';
    if coalesce(p_media, '') = '' or left(p_media, length(v_pre)) <> v_pre then raise exception 'bad media'; end if;
  end if;
  if not exists (select 1 from friendships f where f.a = least(v_me, p_to) and f.b = greatest(v_me, p_to) and f.status = 'accepted') then
    raise exception 'You can only message your friends';
  end if;
  if (select count(*) from messages m where m.sender = v_me and m.created_at > now() - interval '1 minute') >= 20 then
    raise exception 'Slow down a little, then try again';
  end if;
  insert into messages (sender, recipient, body, kind, media)
  values (v_me, p_to, v_text, v_kind, case when v_kind = 'text' then null else p_media end) returning id into v_id;
  return v_id;
end $$;

drop function if exists chat_with(uuid, bigint);
create or replace function chat_with(p_user uuid, p_after bigint default 0)
returns table (id bigint, mine boolean, body text, kind text, media text, created_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = public as $$
  select * from (
    select m.id, m.sender = auth.uid(), m.body, m.kind, m.media, m.created_at, m.read_at
    from messages m
    where ((m.sender = auth.uid() and m.recipient = p_user) or (m.sender = p_user and m.recipient = auth.uid()))
      and m.id > coalesce(p_after, 0)
    order by m.id desc
    limit 200
  ) x order by x.id
$$;

create or replace function my_chats()
returns table (user_id uuid, name text, avatar text, verified boolean, last_body text, last_at timestamptz, last_mine boolean, unread int)
language sql stable security definer set search_path = public as $$
  with m as (
    select case when sender = auth.uid() then recipient else sender end as other, body, kind, created_at, sender, id
    from messages where auth.uid() in (sender, recipient)
  ), last as (
    select distinct on (other) other, body, kind, created_at, sender from m order by other, id desc
  )
  select l.other, p.name, p.avatar,
         coalesce(p.verified and (p.verified_until is null or p.verified_until > now()), false),
         coalesce(nullif(l.body, ''), case l.kind when 'image' then '📷 Photo' when 'video' then '🎬 Video' when 'voice' then '🎙️ Voice note' else '' end),
         l.created_at, l.sender = auth.uid(),
         (select count(*) from messages x where x.recipient = auth.uid() and x.sender = l.other and x.read_at is null)::int
  from last l join profiles p on p.user_id = l.other
  order by l.created_at desc
  limit 100
$$;

revoke execute on function send_message(uuid, text, text, text), chat_with(uuid, bigint), my_chats() from public, anon;
grant execute on function send_message(uuid, text, text, text), chat_with(uuid, bigint), my_chats() to authenticated;
notify pgrst, 'reload schema';
