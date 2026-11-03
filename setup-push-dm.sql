-- Phone alerts for new chat messages. Run once in Supabase SQL Editor.
-- Needs setup-push.sql and setup-presence.sql to have been run first.
create extension if not exists pg_net with schema extensions;

create table if not exists push_dm_log (
  message_id bigint primary key,
  at timestamptz not null default now()
);
alter table push_dm_log enable row level security;
revoke all on push_dm_log from anon, authenticated;

create or replace function notify_dm_push() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  begin
    perform net.http_post(
      url := 'https://zcejqihsmyxplerihser.supabase.co/functions/v1/push-dm',
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object('id', new.id)
    );
  exception when others then null; -- never block sending a message
  end;
  return new;
end $$;

drop trigger if exists messages_push on messages;
create trigger messages_push after insert on messages for each row execute function notify_dm_push();
