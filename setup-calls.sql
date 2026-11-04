-- Voice and video calls between friends. Run once in Supabase SQL Editor.
-- Needs setup-friends.sql and setup-messages.sql first. Safe to run again.
create table if not exists calls (
  id bigint generated always as identity primary key,
  caller uuid not null,
  callee uuid not null,
  kind text not null default 'voice' check (kind in ('voice', 'video')),
  status text not null default 'ringing' check (status in ('ringing', 'active', 'ended', 'declined', 'missed')),
  offer text,
  answer text,
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  ended_at timestamptz,
  check (caller <> callee)
);
create index if not exists calls_callee_idx on calls (callee, status, created_at desc);
create index if not exists calls_caller_idx on calls (caller, created_at desc);
create table if not exists call_ice (
  id bigint generated always as identity primary key,
  call_id bigint not null references calls (id) on delete cascade,
  from_user uuid not null,
  cand text not null
);
create index if not exists call_ice_idx on call_ice (call_id, id);
alter table calls enable row level security;
alter table call_ice enable row level security;
revoke all on calls, call_ice from anon, authenticated;

-- Start a call. p_offer is the browser's connection offer.
create or replace function call_start(p_to uuid, p_kind text, p_offer text) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); v_id bigint;
begin
  if me is null then raise exception 'login required'; end if;
  if p_kind not in ('voice', 'video') then raise exception 'bad kind'; end if;
  if p_offer is null or length(p_offer) > 20000 then raise exception 'bad offer'; end if;
  if not exists (select 1 from friendships f where f.a = least(me, p_to) and f.b = greatest(me, p_to) and f.status = 'accepted') then
    raise exception 'You can only call your friends';
  end if;
  if (select count(*) from calls c where c.caller = me and c.created_at > now() - interval '1 minute') >= 6 then
    raise exception 'Slow down a little, then try again';
  end if;
  -- clean up anything old that is still open
  update calls set status = 'missed', ended_at = now() where status = 'ringing' and created_at < now() - interval '60 seconds';
  update calls set status = 'ended', ended_at = now() where status = 'active' and answered_at < now() - interval '6 hours';
  if exists (select 1 from calls c where c.status in ('ringing', 'active') and (c.callee = p_to or c.caller = p_to)) then
    raise exception 'busy';
  end if;
  insert into calls (caller, callee, kind, offer) values (me, p_to, p_kind, p_offer) returning id into v_id;
  return v_id;
end $$;

-- Is someone calling me right now?
create or replace function call_incoming() returns table (id bigint, caller uuid, name text, avatar text, kind text, offer text)
language sql stable security definer set search_path = public as $$
  select c.id, c.caller, p.name, p.avatar, c.kind, c.offer
  from calls c join profiles p on p.user_id = c.caller
  where c.callee = auth.uid() and c.status = 'ringing' and c.created_at > now() - interval '45 seconds'
  order by c.id desc limit 1;
$$;

create or replace function call_answer(p_id bigint, p_answer text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_answer is null or length(p_answer) > 20000 then raise exception 'bad answer'; end if;
  update calls set status = 'active', answer = p_answer, answered_at = now()
    where id = p_id and callee = auth.uid() and status = 'ringing' and created_at > now() - interval '60 seconds';
  if not found then raise exception 'call is over'; end if;
end $$;

create or replace function call_decline(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare c calls;
begin
  update calls set status = 'declined', ended_at = now() where id = p_id and callee = auth.uid() and status = 'ringing' returning * into c;
  if found then
    insert into messages (sender, recipient, body) values (c.caller, c.callee, case when c.kind = 'video' then E'\U0001F4F9 Video call declined' else E'\U0001F4DE Voice call declined' end);
  end if;
end $$;

-- Either person ends the call. If nobody picked up it counts as missed.
create or replace function call_end(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare c calls; me uuid := auth.uid(); secs int;
begin
  select * into c from calls where id = p_id and (caller = me or callee = me) for update;
  if not found or c.status in ('ended', 'declined', 'missed') then return; end if;
  if c.status = 'ringing' then
    update calls set status = 'missed', ended_at = now() where id = p_id;
    insert into messages (sender, recipient, body) values (c.caller, c.callee, case when c.kind = 'video' then E'\U0001F4F9 Missed video call' else E'\U0001F4DE Missed voice call' end);
  else
    update calls set status = 'ended', ended_at = now() where id = p_id;
    secs := greatest(1, extract(epoch from (now() - c.answered_at))::int);
    insert into messages (sender, recipient, body) values (c.caller, c.callee,
      (case when c.kind = 'video' then E'\U0001F4F9 Video call' else E'\U0001F4DE Voice call' end) || ' ' || (secs / 60) || ':' || lpad((secs % 60)::text, 2, '0'));
  end if;
end $$;

-- State of a call I am part of: status, the answer (for the caller) and new connection hints from the other person.
create or replace function call_state(p_id bigint, p_after bigint default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); c calls; ice jsonb;
begin
  select * into c from calls where id = p_id and (caller = me or callee = me);
  if not found then return jsonb_build_object('status', 'ended'); end if;
  if c.status = 'ringing' and c.created_at < now() - interval '50 seconds' then
    update calls set status = 'missed', ended_at = now() where id = p_id and status = 'ringing';
    insert into messages (sender, recipient, body) values (c.caller, c.callee, case when c.kind = 'video' then E'\U0001F4F9 Missed video call' else E'\U0001F4DE Missed voice call' end);
    c.status := 'missed';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'cand', i.cand) order by i.id), '[]'::jsonb) into ice
    from call_ice i where i.call_id = p_id and i.from_user <> me and i.id > p_after;
  return jsonb_build_object('status', c.status, 'answer', case when me = c.caller then c.answer else null end, 'ice', ice);
end $$;

create or replace function call_ice_add(p_id bigint, p_cand text) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if length(coalesce(p_cand, '')) > 2000 then return; end if;
  if not exists (select 1 from calls where id = p_id and (caller = me or callee = me) and status in ('ringing', 'active')) then return; end if;
  if (select count(*) from call_ice where call_id = p_id and from_user = me) > 80 then return; end if;
  insert into call_ice (call_id, from_user, cand) values (p_id, me, p_cand);
end $$;

grant execute on function call_start(uuid, text, text), call_incoming(), call_answer(bigint, text), call_decline(bigint),
  call_end(bigint), call_state(bigint, bigint), call_ice_add(bigint, text) to authenticated;
revoke execute on function call_start(uuid, text, text), call_incoming(), call_answer(bigint, text), call_decline(bigint),
  call_end(bigint), call_state(bigint, bigint), call_ice_add(bigint, text) from anon, public;

-- Ring the phone of someone who is not on the site (uses the push-dm function).
create or replace function notify_call_push() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  begin
    perform net.http_post(
      url := 'https://zcejqihsmyxplerihser.supabase.co/functions/v1/push-dm',
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object('call', new.id)
    );
  exception when others then null;
  end;
  return new;
end $$;
drop trigger if exists calls_push on calls;
create trigger calls_push after insert on calls for each row execute function notify_call_push();
notify pgrst, 'reload schema';
