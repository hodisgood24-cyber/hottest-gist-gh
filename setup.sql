-- Hottest Gist GH: likes and comments. Paste all of this into Supabase > SQL Editor > Run.

create table if not exists likes (
  post_id text not null,
  client_id text not null,
  primary key (post_id, client_id)
);
create table if not exists comments (
  id bigint generated always as identity primary key,
  post_id text not null,
  client_id text not null,
  name text not null,
  text text not null,
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists comments_post_idx on comments (post_id, created_at);

alter table likes enable row level security;
alter table comments enable row level security;

-- Visitors can only read visible comments. All writing goes through the functions below.
drop policy if exists "read visible comments" on comments;
create policy "read visible comments" on comments for select to anon using (hidden = false);

create or replace view like_counts as
  select post_id, count(*)::int as n from likes group by post_id;
create or replace view comment_counts as
  select post_id, count(*)::int as n from comments where hidden = false group by post_id;

create or replace function toggle_like(p_post text, p_client text, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if length(p_post) > 100 or length(p_client) > 100 then raise exception 'bad input'; end if;
  if p_on then
    insert into likes (post_id, client_id) values (p_post, p_client) on conflict do nothing;
  else
    delete from likes where post_id = p_post and client_id = p_client;
  end if;
end $$;

create or replace function add_comment(p_post text, p_client text, p_name text, p_text text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if length(trim(p_text)) < 1 or length(p_text) > 500 then raise exception 'bad comment'; end if;
  if length(p_name) > 40 or length(p_post) > 100 or length(p_client) > 100 then raise exception 'bad input'; end if;
  if (select count(*) from comments where client_id = p_client and created_at > now() - interval '1 minute') >= 3 then
    raise exception 'slow down';
  end if;
  insert into comments (post_id, client_id, name, text) values (p_post, p_client, trim(p_name), trim(p_text));
end $$;

revoke all on likes, comments from anon, authenticated;
grant select on comments to anon;
grant select on like_counts, comment_counts to anon;
grant execute on function toggle_like(text, text, boolean) to anon;
grant execute on function add_comment(text, text, text, text) to anon;
