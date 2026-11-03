-- Hottest Gist GH: Movies (free films embedded from YouTube). Run once in Supabase > SQL Editor. Safe to run again.
-- Only YouTube links are accepted, so the video stays on YouTube with its owner.
create table if not exists movies (
  id bigint generated always as identity primary key,
  title text not null,
  yt text not null,
  category text not null default 'Other',
  year int,
  description text not null default '',
  status text not null default 'pending' check (status in ('pending', 'live', 'hidden')),
  submitted_by uuid,
  reports int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists movies_live on movies (status, created_at desc);
alter table movies enable row level security;
revoke all on movies from anon, authenticated;

create or replace function movie_list()
returns table (id bigint, title text, yt text, category text, year int, description text, by_name text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.id, m.title, m.yt, m.category, m.year, m.description, p.name, m.created_at
  from movies m left join profiles p on p.user_id = m.submitted_by
  where m.status = 'live' order by m.created_at desc limit 300;
$$;

create or replace function movie_submit(p_title text, p_url text, p_cat text default 'Other', p_year int default null, p_desc text default '')
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); t text := trim(coalesce(p_title, '')); u text := trim(coalesce(p_url, '')); st text;
begin
  if me is null then raise exception 'login required'; end if;
  if length(t) < 2 or length(t) > 100 then raise exception 'Give the film a title (up to 100 characters)'; end if;
  if u !~* '^https?://(www\.|m\.)?(youtube\.com/(watch\?v=|embed/|shorts/)|youtu\.be/)[A-Za-z0-9_-]{6,20}' then raise exception 'Paste a YouTube link to the film'; end if;
  if length(coalesce(p_desc, '')) > 600 then raise exception 'Description is too long'; end if;
  if (select count(*) from movies where submitted_by = me and created_at > now() - interval '1 day') >= 5 then raise exception 'You can submit up to 5 films a day'; end if;
  st := case when is_admin() then 'live' else 'pending' end;
  insert into movies (title, yt, category, year, description, status, submitted_by)
  values (t, u, left(coalesce(nullif(trim(p_cat), ''), 'Other'), 30), p_year, trim(coalesce(p_desc, '')), st, me);
  return st;
end $$;

create or replace function movie_report(p_id bigint) returns void
language sql security definer set search_path = public as $$
  update movies set reports = reports + 1 where id = p_id and auth.uid() is not null;
$$;

create or replace function admin_movies()
returns table (id bigint, title text, yt text, category text, status text, reports int, by_name text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return query select m.id, m.title, m.yt, m.category, m.status, m.reports, p.name, m.created_at
    from movies m left join profiles p on p.user_id = m.submitted_by
    order by (m.status = 'pending') desc, m.reports desc, m.created_at desc limit 200;
end $$;

create or replace function admin_movie_set(p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_status not in ('pending', 'live', 'hidden') then raise exception 'bad status'; end if;
  update movies set status = p_status where id = p_id;
end $$;

create or replace function admin_movie_delete(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  delete from movies where id = p_id;
end $$;

revoke execute on function movie_list(), movie_submit(text, text, text, int, text), movie_report(bigint), admin_movies(), admin_movie_set(bigint, text), admin_movie_delete(bigint) from public;
grant execute on function movie_list() to anon, authenticated;
grant execute on function movie_submit(text, text, text, int, text), movie_report(bigint), admin_movies(), admin_movie_set(bigint, text), admin_movie_delete(bigint) to authenticated;
notify pgrst, 'reload schema';
