-- 24-hour Stories. Run once in Supabase -> SQL Editor.
create table if not exists stories (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  media text,
  body text not null default '',
  bg int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists stories_recent on stories (created_at desc);
alter table stories enable row level security;
revoke all on stories from anon, authenticated;

create or replace function story_add(p_media text default null, p_body text default '', p_bg int default 0)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_pre text; v_id bigint; v_text text := trim(coalesce(p_body,''));
begin
  if v_me is null then raise exception 'login required'; end if;
  if length(v_text) > 280 then raise exception 'Stories can be up to 280 characters'; end if;
  if coalesce(p_media,'') = '' and v_text = '' then raise exception 'Add a photo or some text'; end if;
  if coalesce(p_media,'') <> '' then
    v_pre := 'https://zcejqihsmyxplerihser.supabase.co/storage/v1/object/public/fan-media/' || v_me::text || '/';
    if left(p_media, length(v_pre)) <> v_pre then raise exception 'bad media'; end if;
  end if;
  if (select count(*) from stories s where s.user_id = v_me and s.created_at > now() - interval '24 hours') >= 15 then
    raise exception 'You can post up to 15 stories a day';
  end if;
  insert into stories (user_id, media, body, bg) values (v_me, nullif(p_media,''), v_text, greatest(0, least(coalesce(p_bg,0), 7))) returning id into v_id;
  return v_id;
end $$;

create or replace function story_delete(p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from stories where id = p_id and user_id = auth.uid();
$$;

create or replace function story_list()
returns table (id bigint, user_id uuid, name text, avatar text, verified boolean, media text, body text, bg int, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select s.id, s.user_id, p.name, p.avatar, p.verified, s.media, s.body, s.bg, s.created_at
  from stories s join profiles p on p.user_id = s.user_id
  where s.created_at > now() - interval '24 hours'
  order by s.created_at asc
  limit 300;
$$;

grant execute on function story_add(text, text, int) to authenticated;
grant execute on function story_delete(bigint) to authenticated;
grant execute on function story_list() to anon, authenticated;
